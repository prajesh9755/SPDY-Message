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

// ─── Upload progress model ───
class UploadingFile {
  final String id;
  final String fileName;
  final String fileType;
  int totalBytes;
  int bytesTransferred;
  String stage; // 'compressing', 'encrypting', 'uploading', 'done'
  DateTime? _uploadStartTime;

  UploadingFile({
    required this.id,
    required this.fileName,
    required this.fileType,
    required this.totalBytes,
    this.bytesTransferred = 0,
    this.stage = 'compressing',
  });

  void markUploadStarted() {
    _uploadStartTime = DateTime.now();
  }

  double get progress {
    if (stage == 'compressing' || stage == 'encrypting') return -1;
    if (totalBytes <= 0) return 0;
    return (bytesTransferred / totalBytes).clamp(0.0, 1.0);
  }

  String get stageText {
    switch (stage) {
      case 'compressing':
        return 'Compressing...';
      case 'encrypting':
        return 'Encrypting...';
      case 'uploading':
        return 'Uploading';
      default:
        return '';
    }
  }

  String get remainingTimeText {
    if (stage != 'uploading' ||
        _uploadStartTime == null ||
        bytesTransferred <= 0)
      return '';
    final elapsed = DateTime.now().difference(_uploadStartTime!).inMilliseconds;
    if (elapsed < 500) return '';
    final speed = bytesTransferred / elapsed;
    if (speed <= 0) return '';
    final remaining = totalBytes - bytesTransferred;
    final remainingSec = (remaining / speed / 1000).round();
    if (remainingSec <= 0) return 'Almost done...';
    if (remainingSec < 60) return '~${remainingSec}s left';
    return '~${(remainingSec / 60).ceil()}m left';
  }

  static String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1048576) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1048576).toStringAsFixed(1)} MB';
  }
}

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
  final _scrollController = ScrollController();
  SecretKey? _sharedKey;
  bool _isKeyReady = false;
  String _recipientName = "";

  final Map<String, dynamic> _decryptedCache = {};
  final Map<String, UploadingFile> _uploadingFiles = {};

  @override
  void initState() {
    super.initState();
    _initializeEncryption();
    _fetchRecipientName();
  }

  Future<void> _fetchRecipientName() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(widget.recipientId)
          .get();
      if (doc.exists && mounted) {
        setState(() {
          _recipientName = (doc.data()?['phoneNumber'] as String?) ?? 'Chat';
        });
      }
    } catch (_) {}
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
          SnackBar(
            content: const Text(
              "Unable to establish secure connection. Try restarting.",
            ),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            backgroundColor: Colors.red.shade700,
            margin: const EdgeInsets.all(16),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }
  }

  Future<void> _sendMessage() async {
    if (_sharedKey == null || _messageController.text.trim().isEmpty) return;

    final messageText = _messageController.text.trim();
    _messageController.clear();

    try {
      final encrypted = await CryptoService.encryptText(
        messageText,
        _sharedKey!,
      );

      final batch = FirebaseFirestore.instance.batch();

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

      final chatRef = FirebaseFirestore.instance
          .collection('chats')
          .doc(widget.chatId);

      batch.update(chatRef, {
        'lastMessageTimestamp': FieldValue.serverTimestamp(),
        'lastMessage': "[Encrypted Message]",
      });

      await batch.commit();
    } catch (e) {
      debugPrint("❌ SEND ERROR: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text("Failed to send message"),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            margin: const EdgeInsets.all(16),
          ),
        );
      }
    }
  }

  Future<dynamic> _getDecryptedMessage(DocumentSnapshot doc) async {
    final docId = doc.id;

    if (_decryptedCache.containsKey(docId)) {
      return _decryptedCache[docId]!;
    }

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
      builder: (c) => Center(
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
          ),
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: Color(0xFF25D366)),
              SizedBox(height: 16),
              Text("Decrypting file...", style: TextStyle(fontSize: 14)),
            ],
          ),
        ),
      ),
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

      if (mounted) Navigator.pop(context);
      await OpenFile.open(tempFile.path);
    } catch (e) {
      debugPrint("File open error: $e");
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text("Failed to open file"),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            margin: const EdgeInsets.all(16),
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
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
        withData: false,
      );
      if (result != null) {
        pickedFiles = result.files;
      }
    } else {
      final ImagePicker picker = ImagePicker();
      List<XFile> xFiles = [];

      if (type == 'video') {
        final file = await picker.pickVideo(source: ImageSource.gallery);
        if (file != null) xFiles.add(file);
      } else {
        final files = await picker.pickMultiImage();
        xFiles.addAll(files);
      }

      for (var x in xFiles) {
        final length = await x.length();
        pickedFiles.add(PlatformFile(name: x.name, path: x.path, size: length));
      }
    }

    if (pickedFiles.isEmpty || _sharedKey == null) return;

    final uploadId = DateTime.now().millisecondsSinceEpoch.toString();

    // Add files to uploading list immediately (appear as bubbles)
    setState(() {
      for (int i = 0; i < pickedFiles.length; i++) {
        final pf = pickedFiles[i];
        final ext = pf.extension?.toLowerCase() ?? '';
        String ft = 'image';
        if (['pdf', 'doc', 'docx'].contains(ext))
          ft = 'pdf';
        else if (['mp4', 'mov', 'avi', 'mkv', 'flv', 'wmv'].contains(ext))
          ft = 'video';

        _uploadingFiles['${uploadId}_$i'] = UploadingFile(
          id: '${uploadId}_$i',
          fileName: pf.name,
          fileType: ft,
          totalBytes: pf.size,
        );
      }
    });

    try {
      final originalFiles = pickedFiles;
      final renamedNames = originalFiles.map((f) => f.name).toList();

      final compressedFiles = await Compressor.compressFiles(
        originalFiles,
        renamedNames,
      );

      // Update to encrypted sizes after compression
      if (mounted) {
        setState(() {
          for (int i = 0; i < compressedFiles.length; i++) {
            final key = '${uploadId}_$i';
            if (_uploadingFiles.containsKey(key)) {
              _uploadingFiles[key]!.totalBytes = compressedFiles[i].size;
              _uploadingFiles[key]!.stage = 'encrypting';
            }
          }
        });
      }

      await uploadChatFiles(
        compressedFiles,
        widget.chatId,
        _sharedKey!,
        onFileCompleted: (_) {},
        onProgress: (fileIndex, stage, bytesTransferred, totalBytes) {
          if (!mounted) return;
          final key = '${uploadId}_$fileIndex';
          setState(() {
            if (_uploadingFiles.containsKey(key)) {
              final uf = _uploadingFiles[key]!;
              if (stage == 'uploading' && uf.stage != 'uploading') {
                uf.markUploadStarted();
              }
              uf.stage = stage;
              uf.bytesTransferred = bytesTransferred;
              if (totalBytes > 0) uf.totalBytes = totalBytes;
              if (stage == 'done' || stage == 'error') {
                _uploadingFiles.remove(key);
              }
            }
          });
        },
      );
    } catch (e) {
      debugPrint("❌ DIRECT UPLOAD ERROR: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text("Failed to send files"),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            margin: const EdgeInsets.all(16),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _uploadingFiles.removeWhere((key, _) => key.startsWith(uploadId));
        });
      }
    }
  }

  void _showAttachmentBottomSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        margin: const EdgeInsets.all(12),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle bar
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _buildAttachmentOption(
                  icon: Icons.insert_drive_file,
                  color: const Color(0xFF7C4DFF),
                  label: "Document",
                  onTap: () => _pickAndUploadFiles('pdf'),
                ),
                _buildAttachmentOption(
                  icon: Icons.photo,
                  color: const Color(0xFFE91E63),
                  label: "Gallery",
                  onTap: () => _pickAndUploadFiles('image'),
                ),
                _buildAttachmentOption(
                  icon: Icons.videocam,
                  color: const Color(0xFFFF6D00),
                  label: "Video",
                  onTap: () => _pickAndUploadFiles('video'),
                ),
              ],
            ),
            const SizedBox(height: 16),
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
          Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(icon, size: 28, color: Colors.white),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              color: Colors.grey.shade700,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  String _formatTime(Timestamp? timestamp) {
    if (timestamp == null) return "";
    final dt = timestamp.toDate();
    return "${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}";
  }

  @override
  Widget build(BuildContext context) {
    final currentUserId = FirebaseAuth.instance.currentUser!.uid;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF075E54),
        leadingWidth: 28,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, size: 22),
          onPressed: () => Navigator.pop(context),
          padding: EdgeInsets.zero,
        ),
        titleSpacing: 0,
        title: Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: Colors.teal.shade300,
              child: const Icon(Icons.person, color: Colors.white, size: 20),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _recipientName.isNotEmpty ? _recipientName : "Chat",
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (_isKeyReady)
                    const Text(
                      "end-to-end encrypted",
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.normal,
                        color: Colors.white70,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'info', child: Text('Contact info')),
              const PopupMenuItem(
                value: 'media',
                child: Text('Media, links, docs'),
              ),
              const PopupMenuItem(value: 'search', child: Text('Search')),
              const PopupMenuItem(value: 'wallpaper', child: Text('Wallpaper')),
            ],
          ),
        ],
      ),
      body: Container(
        // WhatsApp chat wallpaper
        decoration: const BoxDecoration(color: Color(0xFFECE5DD)),
        child: Column(
          children: [
            // E2E encryption notice
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 48, vertical: 8),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF3C4).withOpacity(0.9),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                "🔒 Messages are end-to-end encrypted. No one outside "
                "of this chat can read or listen to them.",
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11,
                  color: Color(0xFF57534E),
                  height: 1.3,
                ),
              ),
            ),

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
                          return Center(
                            child: Text(
                              "Error: ${snapshot.error}",
                              style: TextStyle(color: Colors.grey.shade600),
                            ),
                          );
                        }

                        if (!snapshot.hasData) {
                          return const Center(
                            child: CircularProgressIndicator(
                              color: Color(0xFF25D366),
                            ),
                          );
                        }

                        final messages = snapshot.data!.docs;

                        if (messages.isEmpty) {
                          return const Center(
                            child: Text(
                              "Say hello! 👋",
                              style: TextStyle(
                                color: Colors.grey,
                                fontSize: 16,
                              ),
                            ),
                          );
                        }

                        final uploadsList = _uploadingFiles.values.toList();
                        return ListView.builder(
                          controller: _scrollController,
                          reverse: true,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          itemCount: messages.length + uploadsList.length,
                          itemBuilder: (context, index) {
                            if (index < uploadsList.length) {
                              return _buildUploadProgressBubble(
                                uploadsList[index],
                              );
                            }
                            final doc = messages[index - uploadsList.length];
                            final isMine = doc['sender'] == currentUserId;
                            final timestamp = doc['timestamp'] as Timestamp?;

                            return FutureBuilder<dynamic>(
                              future: _getDecryptedMessage(doc),
                              builder: (context, snapshot) {
                                if (!snapshot.hasData) {
                                  return _buildBubbleShimmer(isMine);
                                }

                                final isText = doc['type'] == 'text';

                                return _buildMessageBubble(
                                  isMine: isMine,
                                  isText: isText,
                                  content: snapshot.data,
                                  type: doc['type'],
                                  timestamp: timestamp,
                                  onFileTap: isText
                                      ? null
                                      : () {
                                          if (snapshot.data is Map) {
                                            _openFile(
                                              snapshot.data
                                                  as Map<String, dynamic>,
                                            );
                                          }
                                        },
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
                          CircularProgressIndicator(color: Color(0xFF25D366)),
                          SizedBox(height: 16),
                          Text(
                            "Establishing secure connection...",
                            style: TextStyle(color: Colors.grey, fontSize: 14),
                          ),
                        ],
                      ),
                    ),
            ),

            // Message Input Bar
            _buildInputBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildBubbleShimmer(bool isMine) {
    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: EdgeInsets.only(
          bottom: 3,
          left: isMine ? 60 : 8,
          right: isMine ? 8 : 60,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isMine
              ? const Color(0xFFDCF8C6).withOpacity(0.7)
              : Colors.white.withOpacity(0.7),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(12),
            topRight: const Radius.circular(12),
            bottomLeft: Radius.circular(isMine ? 12 : 0),
            bottomRight: Radius.circular(isMine ? 0 : 12),
          ),
        ),
        child: const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: Color(0xFF075E54),
          ),
        ),
      ),
    );
  }

  Widget _buildMessageBubble({
    required bool isMine,
    required bool isText,
    required dynamic content,
    required String type,
    required Timestamp? timestamp,
    VoidCallback? onFileTap,
  }) {
    final timeString = _formatTime(timestamp);

    Widget messageContent;

    if (isText) {
      messageContent = Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Flexible(
            child: Text(
              content is String
                  ? content
                  : (content is Map
                        ? (content['name'] ?? content.toString())
                        : content?.toString() ?? ''),
              style: const TextStyle(
                color: Color(0xFF303030),
                fontSize: 15,
                height: 1.3,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Padding(
            padding: const EdgeInsets.only(bottom: 0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  timeString,
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                ),
                if (isMine) ...[
                  const SizedBox(width: 3),
                  Icon(Icons.done_all, size: 16, color: Colors.blue.shade400),
                ],
              ],
            ),
          ),
        ],
      );
    } else {
      // File message
      IconData fileIcon;
      Color fileColor;

      if (type == 'pdf') {
        fileIcon = Icons.picture_as_pdf;
        fileColor = Colors.red.shade400;
      } else if (type == 'video') {
        fileIcon = Icons.play_circle_filled;
        fileColor = const Color(0xFFFF6D00);
      } else {
        fileIcon = Icons.image;
        fileColor = const Color(0xFFE91E63);
      }

      final fileName = (content is Map) ? (content['name'] ?? 'File') : 'File';

      messageContent = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: isMine ? const Color(0xFFC5E8B0) : Colors.grey.shade100,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: fileColor.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(fileIcon, color: fileColor, size: 22),
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        fileName,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF303030),
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        type.toUpperCase(),
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Text(
                timeString,
                style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
              ),
              if (isMine) ...[
                const SizedBox(width: 3),
                Icon(Icons.done_all, size: 16, color: Colors.blue.shade400),
              ],
            ],
          ),
        ],
      );
    }

    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onTap: onFileTap,
        child: Container(
          margin: EdgeInsets.only(
            bottom: 3,
            left: isMine ? 60 : 8,
            right: isMine ? 8 : 60,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.75,
          ),
          decoration: BoxDecoration(
            color: isMine ? const Color(0xFFDCF8C6) : Colors.white,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(12),
              topRight: const Radius.circular(12),
              bottomLeft: Radius.circular(isMine ? 12 : 0),
              bottomRight: Radius.circular(isMine ? 0 : 12),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.04),
                blurRadius: 2,
                offset: const Offset(0, 1),
              ),
            ],
          ),
          child: messageContent,
        ),
      ),
    );
  }

  // ─── WhatsApp-style upload progress bubble ───
  Widget _buildUploadProgressBubble(UploadingFile upload) {
    final isUploading = upload.stage == 'uploading';
    final progressVal = isUploading ? upload.progress : null;

    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.only(bottom: 3, left: 60, right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        decoration: BoxDecoration(
          color: const Color(0xFFDCF8C6), // Light green like mine bubbles
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(12),
            topRight: Radius.circular(12),
            bottomLeft: Radius.circular(12),
            bottomRight: Radius.circular(0),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.04),
              blurRadius: 2,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Circular progress with percentage
            SizedBox(
              width: 44,
              height: 44,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  CircularProgressIndicator(
                    value: progressVal,
                    strokeWidth: 3,
                    color: const Color(0xFF075E54),
                    backgroundColor: Colors.black12,
                  ),
                  if (isUploading && upload.progress >= 0)
                    Text(
                      '${(upload.progress * 100).toInt()}%',
                      style: TextStyle(
                        color: Colors.grey.shade800,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    )
                  else
                    Icon(
                      upload.fileType == 'pdf'
                          ? Icons.picture_as_pdf
                          : upload.fileType == 'video'
                          ? Icons.play_circle_filled
                          : Icons.image,
                      color: const Color(0xFF075E54),
                      size: 20,
                    ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            // File details
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    upload.fileName,
                    style: const TextStyle(
                      color: Color(0xFF303030),
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  if (isUploading) ...[
                    Text(
                      '${UploadingFile.formatBytes(upload.bytesTransferred)} / ${UploadingFile.formatBytes(upload.totalBytes)}',
                      style: TextStyle(
                        color: Colors.grey.shade700,
                        fontSize: 11,
                      ),
                    ),
                    if (upload.remainingTimeText.isNotEmpty)
                      Text(
                        upload.remainingTimeText,
                        style: TextStyle(
                          color: Colors.grey.shade700,
                          fontSize: 11,
                        ),
                      ),
                  ] else
                    Text(
                      '${upload.stageText} • ${UploadingFile.formatBytes(upload.totalBytes)}',
                      style: TextStyle(
                        color: Colors.grey.shade700,
                        fontSize: 11,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInputBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      color: const Color(0xFFECE5DD),
      child: Row(
        children: [
          // Text field with emoji + attach
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(25),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.05),
                    blurRadius: 3,
                    offset: const Offset(0, 1),
                  ),
                ],
              ),
              child: Row(
                children: [
                  IconButton(
                    icon: Icon(
                      Icons.emoji_emotions_outlined,
                      color: Colors.grey.shade600,
                      size: 24,
                    ),
                    onPressed: () {},
                    padding: const EdgeInsets.only(left: 8),
                    constraints: const BoxConstraints(),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _messageController,
                      decoration: const InputDecoration(
                        hintText: "Type a message",
                        hintStyle: TextStyle(color: Colors.grey, fontSize: 15),
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 10,
                        ),
                      ),
                      style: const TextStyle(fontSize: 15),
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _sendMessage(),
                      maxLines: 5,
                      minLines: 1,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(
                      Icons.attach_file,
                      color: Colors.grey,
                      size: 24,
                    ),
                    onPressed: _showAttachmentBottomSheet,
                    constraints: const BoxConstraints(),
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                  ),
                  IconButton(
                    icon: Icon(
                      Icons.camera_alt,
                      color: Colors.grey.shade600,
                      size: 22,
                    ),
                    onPressed: () => _pickAndUploadFiles('image'),
                    constraints: const BoxConstraints(),
                    padding: const EdgeInsets.only(right: 8),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 6),

          // Send / mic button
          Container(
            width: 48,
            height: 48,
            decoration: const BoxDecoration(
              color: Color(0xFF25D366),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Colors.black12,
                  blurRadius: 3,
                  offset: Offset(0, 1),
                ),
              ],
            ),
            child: IconButton(
              icon: const Icon(Icons.send, color: Colors.white, size: 22),
              onPressed: _isKeyReady ? _sendMessage : null,
              padding: EdgeInsets.zero,
            ),
          ),
        ],
      ),
    );
  }
}
