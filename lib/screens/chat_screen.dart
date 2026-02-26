import 'dart:io';
import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cryptography/cryptography.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_file/open_file.dart';
import '../services/compressor.dart';
import '../services/firebase_uploader.dart';
import '../services/crypto_service.dart';

class ChatScreen extends StatefulWidget {
  final String chatId;
  final String recipientId;
  final String otherUserPublicKey;

  const ChatScreen({
    super.key,
    required this.chatId,
    required this.recipientId,
    required this.otherUserPublicKey,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _messageController = TextEditingController();
  SecretKey? _sharedKey;
  bool _isKeyReady = false;

  // 🔥 THIS FIXES THE "SKIPPED FRAMES" ERROR
  // Cache decrypted messages so we don't decrypt repeatedly
  final Map<String, dynamic> _decryptedCache = {};

  @override
  void initState() {
    super.initState();
    _initializeEncryption();
  }

  Future<void> _initializeEncryption() async {
    try {
      if (widget.otherUserPublicKey.isEmpty) {
        throw Exception("Other user's public key is missing");
      }

      _sharedKey = await CryptoService.deriveSharedKey(
        widget.otherUserPublicKey,
      );

      if (mounted) {
        setState(() => _isKeyReady = true);
      }
    } catch (e) {
      debugPrint("❌ KEY DERIVATION ERROR: $e");

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              "Unable to establish secure connection. Try restarting.",
            ),
            duration: Duration(seconds: 4),
          ),
        );
      }
    }
  }

  // Future<void> _sendMessage() async {
  //   if (_sharedKey == null || _messageController.text.trim().isEmpty) return;

  //   final messageText = _messageController.text.trim();
  //   _messageController.clear();

  //   try {
  //     final encrypted = await CryptoService.encryptText(
  //       messageText,
  //       _sharedKey!,
  //     );

  //     await FirebaseFirestore.instance
  //         .collection('chats')
  //         .doc(widget.chatId)
  //         .collection('messages')
  //         .add({
  //       'sender': FirebaseAuth.instance.currentUser!.uid,
  //       'cipher': encrypted['cipher'],
  //       'nonce': encrypted['nonce'],
  //       'mac': encrypted['mac'],
  //       'type': 'text',
  //       'timestamp': FieldValue.serverTimestamp(),
  //     });
  //   } catch (e) {
  //     debugPrint("❌ SEND ERROR: $e");
  //     if (mounted) {
  //       ScaffoldMessenger.of(context).showSnackBar(
  //         const SnackBar(content: Text("Failed to send message")),
  //       );
  //     }
  //   }
  // }

  Future<void> _sendMessage() async {
    if (_sharedKey == null || _messageController.text.trim().isEmpty) return;

    final messageText = _messageController.text.trim();
    _messageController.clear();

    try {
      final encrypted = await CryptoService.encryptText(
        messageText,
        _sharedKey!,
      );

      // 1. Create a Batch to ensure both updates happen together
      final batch = FirebaseFirestore.instance.batch();

      // 2. Reference for the new message
      final messageRef = FirebaseFirestore.instance
          .collection('chats')
          .doc(widget.chatId)
          .collection('messages')
          .doc();

      batch.set(messageRef, {
        'sender': FirebaseAuth.instance.currentUser!.uid,
        'cipher': encrypted['cipher'],
        'nonce': encrypted['nonce'],
        'mac': encrypted['mac'],
        'type': 'text',
        'timestamp': FieldValue.serverTimestamp(),
      });

      // 3. 🔥 UPDATE THE PARENT CHAT DOCUMENT
      // This ensures the Home Screen knows a new message arrived
      final chatRef = FirebaseFirestore.instance
          .collection('chats')
          .doc(widget.chatId);

      batch.update(chatRef, {
        'lastMessageTimestamp': FieldValue.serverTimestamp(), // For sorting
        'lastMessage': "[Encrypted Message]", // Placeholder text
      });

      // 4. Commit the batch
      await batch.commit();
    } catch (e) {
      debugPrint("❌ SEND ERROR: $e");
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text("Failed to send message")));
      }
    }
  }

  /// Decrypt and cache messages to avoid repeated decryption
  Future<dynamic> _getDecryptedMessage(DocumentSnapshot doc) async {
    final docId = doc.id;

    // Return cached version if available
    if (_decryptedCache.containsKey(docId)) {
      return _decryptedCache[docId]!;
    }

    // Decrypt and cache
    try {
      final decrypted = await CryptoService.decryptText({
        'cipher': doc['cipher'],
        'nonce': doc['nonce'],
        'mac': doc['mac'],
      }, _sharedKey!);

      final isText = doc['type'] == 'text';
      dynamic parsed;
      if (isText) {
        parsed = decrypted;
      } else {
        try {
          parsed = jsonDecode(decrypted);
          if (parsed is! Map) {
            parsed = {"name": parsed.toString()};
          }
        } catch (e) {
          parsed = {"name": "[Invalid File Data]"};
        }
      }

      _decryptedCache[docId] = parsed;
      return parsed;
    } catch (e) {
      debugPrint("❌ DECRYPT ERROR: $e");
      return doc['type'] == 'text'
          ? "[Decryption failed]"
          : {"name": "[Decryption failed]"};
    }
  }

  Future<void> _openFile(Map<String, dynamic> fileData) async {
    if (_sharedKey == null) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (c) => const Center(child: CircularProgressIndicator()),
    );

    try {
      final url = fileData['url'];
      final name = fileData['name'];
      final nonce = fileData['fileNonce'];
      final mac = fileData['fileMac'];

      if (url == null) throw Exception("No file URL");

      final request = await HttpClient().getUrl(Uri.parse(url));
      final response = await request.close();
      final encryptedBytes = await consolidateHttpClientResponseBytes(response);

      final decryptedBytes = await CryptoService.decryptFile(
        encryptedBytes,
        nonce,
        mac,
        _sharedKey!,
      );

      final tempDir = await getTemporaryDirectory();
      final tempFile = File('${tempDir.path}/$name');
      await tempFile.writeAsBytes(decryptedBytes, flush: true);

      if (mounted) Navigator.pop(context); // close dialog
      await OpenFile.open(tempFile.path);
    } catch (e) {
      debugPrint("File open error: $e");
      if (mounted) {
        Navigator.pop(context); // close dialog
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Failed to open file')));
      }
    }
  }

  @override
  void dispose() {
    _messageController.dispose();
    _decryptedCache.clear();
    super.dispose();
  }

  Future<void> _pickAndUploadFiles(String type) async {
    Navigator.pop(context); // Close bottom sheet

    List<PlatformFile> pickedFiles = [];

    if (type == 'pdf') {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.custom,
        allowedExtensions: ['pdf', 'doc', 'docx'],
        withData: false, // We only need paths
      );
      if (result != null) {
        pickedFiles = result.files;
      }
    } else {
      final ImagePicker picker = ImagePicker();
      List<XFile> xFiles = [];

      if (type == 'video') {
        // Pick one video from gallery
        final file = await picker.pickVideo(source: ImageSource.gallery);
        if (file != null) xFiles.add(file);
      } else {
        // Pick multiple images from gallery
        final files = await picker.pickMultiImage();
        xFiles.addAll(files);
      }

      // Convert XFile into PlatformFile to match our existing compressor logic flow
      for (var x in xFiles) {
        final length = await x.length();
        pickedFiles.add(PlatformFile(name: x.name, path: x.path, size: length));
      }
    }

    if (pickedFiles.isEmpty) return;
    if (_sharedKey == null) return;

    // Show loading dialog
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (c) => const Center(child: CircularProgressIndicator()),
    );

    try {
      final originalFiles = pickedFiles;
      final renamedNames = originalFiles
          .map((f) => f.name)
          .toList(); // Keep original names

      // Compress files locally using our Compressor logic
      final compressedFiles = await Compressor.compressFiles(
        originalFiles,
        renamedNames,
      );

      // Upload directly utilizing our existing Firebase encrypted method
      await uploadChatFiles(
        compressedFiles,
        widget.chatId,
        _sharedKey!,
        onFileCompleted: (_) {},
      );
    } catch (e) {
      debugPrint("❌ DIRECT UPLOAD ERROR: $e");
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Failed to send files')));
      }
    } finally {
      if (mounted) Navigator.pop(context); // Close loading dialog
    }
  }

  void _showAttachmentBottomSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        height: 286,
        margin: const EdgeInsets.all(12),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _buildAttachmentOption(
                  icon: Icons.insert_drive_file,
                  color: Colors.indigo,
                  label: "Document",
                  onTap: () => _pickAndUploadFiles('pdf'),
                ),
                _buildAttachmentOption(
                  icon: Icons.image,
                  color: Colors.pink,
                  label: "Gallery",
                  onTap: () => _pickAndUploadFiles('image'),
                ),
                _buildAttachmentOption(
                  icon: Icons.videocam,
                  color: Colors.orange,
                  label: "Video",
                  onTap: () => _pickAndUploadFiles('video'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAttachmentOption({
    required IconData icon,
    required Color color,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          CircleAvatar(
            radius: 30,
            backgroundColor: color,
            child: Icon(icon, size: 28, color: Colors.white),
          ),
          const SizedBox(height: 8),
          Text(label, style: const TextStyle(fontSize: 14)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final currentUserId = FirebaseAuth.instance.currentUser!.uid;

    return Scaffold(
      appBar: AppBar(
        title: const Text("Secure Chat"),
        backgroundColor: Colors.green,
      ),
      body: Column(
        children: [
          // Message List
          Expanded(
            child: _isKeyReady
                ? StreamBuilder<QuerySnapshot>(
                    stream: FirebaseFirestore.instance
                        .collection('chats')
                        .doc(widget.chatId)
                        .collection('messages')
                        .orderBy('timestamp', descending: true)
                        .snapshots(),
                    builder: (context, snapshot) {
                      if (snapshot.hasError) {
                        return Center(child: Text("Error: ${snapshot.error}"));
                      }

                      if (!snapshot.hasData) {
                        return const Center(child: CircularProgressIndicator());
                      }

                      final messages = snapshot.data!.docs;

                      if (messages.isEmpty) {
                        return const Center(
                          child: Text(
                            "Start a secure conversation",
                            style: TextStyle(color: Colors.grey),
                          ),
                        );
                      }

                      return ListView.builder(
                        reverse: true,
                        padding: const EdgeInsets.all(12),
                        itemCount: messages.length,
                        itemBuilder: (context, index) {
                          final doc = messages[index];
                          final isMine = doc['sender'] == currentUserId;

                          return FutureBuilder<dynamic>(
                            future: _getDecryptedMessage(doc),
                            builder: (context, snapshot) {
                              if (!snapshot.hasData) {
                                return Align(
                                  alignment: isMine
                                      ? Alignment.centerRight
                                      : Alignment.centerLeft,
                                  child: Container(
                                    margin: const EdgeInsets.only(bottom: 8),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 8,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.grey.shade300,
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    ),
                                  ),
                                );
                              }

                              final isText = doc['type'] == 'text';
                              final content = isText
                                  ? Text(
                                      snapshot.data! as String,
                                      style: TextStyle(
                                        color: isMine
                                            ? Colors.white
                                            : Colors.black87,
                                        fontSize: 15,
                                      ),
                                    )
                                  : Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          doc['type'] == 'pdf'
                                              ? Icons.picture_as_pdf
                                              : (doc['type'] == 'video'
                                                    ? Icons.videocam
                                                    : Icons.image),
                                          color: isMine
                                              ? Colors.white
                                              : Colors.black87,
                                        ),
                                        const SizedBox(width: 8),
                                        Flexible(
                                          // Wrap Text in Flexible
                                          child: Text(
                                            (snapshot.data is Map)
                                                ? (snapshot.data
                                                          as Map)['name'] ??
                                                      'File'
                                                : 'File',
                                            style: TextStyle(
                                              color: isMine
                                                  ? Colors.white
                                                  : Colors.black87,
                                              fontWeight: FontWeight.bold,
                                            ),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ],
                                    );

                              return Align(
                                alignment: isMine
                                    ? Alignment.centerRight
                                    : Alignment.centerLeft,
                                child: GestureDetector(
                                  onTap: isText
                                      ? null
                                      : () {
                                          if (snapshot.data is Map) {
                                            _openFile(
                                              snapshot.data
                                                  as Map<String, dynamic>,
                                            );
                                          }
                                        },
                                  child: Container(
                                    margin: const EdgeInsets.only(bottom: 8),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 14,
                                      vertical: 10,
                                    ),
                                    constraints: BoxConstraints(
                                      maxWidth:
                                          MediaQuery.of(context).size.width *
                                          0.7,
                                    ),
                                    decoration: BoxDecoration(
                                      color: isMine
                                          ? Colors.green.shade400
                                          : Colors.grey.shade300,
                                      borderRadius: BorderRadius.circular(16),
                                    ),
                                    child: content,
                                  ),
                                ),
                              );
                            },
                          );
                        },
                      );
                    },
                  )
                : const Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 16),
                        Text("Establishing secure connection..."),
                      ],
                    ),
                  ),
          ),

          // Message Input
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.white,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.05),
                  blurRadius: 4,
                  offset: const Offset(0, -2),
                ),
              ],
            ),
            child: Row(
              children: [
                // 🔥 New + Button
                IconButton(
                  icon: const Icon(
                    Icons.attach_file,
                    color: Colors.grey,
                    size: 26,
                  ),
                  onPressed: _showAttachmentBottomSheet,
                ),
                const SizedBox(width: 4), // Tiny gap before text field

                Expanded(
                  child: TextField(
                    controller: _messageController,
                    decoration: InputDecoration(
                      hintText: "Type a message...",
                      filled: true,
                      fillColor: Colors.grey.shade100,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                    ),
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _sendMessage(),
                  ),
                ),
                const SizedBox(width: 8),
                CircleAvatar(
                  backgroundColor: _isKeyReady ? Colors.green : Colors.grey,
                  child: IconButton(
                    icon: const Icon(Icons.send, color: Colors.white),
                    onPressed: _isKeyReady ? _sendMessage : null,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
