import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cryptography/cryptography.dart';
import 'package:spdy_message/screens/upload_page.dart';
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
  final Map<String, String> _decryptedCache = {};

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
            content: Text("Unable to establish secure connection. Try restarting."),
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
      final chatRef = FirebaseFirestore.instance.collection('chats').doc(widget.chatId);
      
      batch.update(chatRef, {
        'lastMessageTimestamp': FieldValue.serverTimestamp(), // For sorting
        'lastMessage': "[Encrypted Message]", // Placeholder text
      });

      // 4. Commit the batch
      await batch.commit();

    } catch (e) {
      debugPrint("❌ SEND ERROR: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Failed to send message")),
        );
      }
    }
  }

  /// Decrypt and cache messages to avoid repeated decryption
  Future<String> _getDecryptedMessage(DocumentSnapshot doc) async {
    final docId = doc.id;

    // Return cached version if available
    if (_decryptedCache.containsKey(docId)) {
      return _decryptedCache[docId]!;
    }

    // Decrypt and cache
    try {
      final decrypted = await CryptoService.decryptText(
        {
          'cipher': doc['cipher'],
          'nonce': doc['nonce'],
          'mac': doc['mac'],
        },
        _sharedKey!,
      );

      _decryptedCache[docId] = decrypted;
      return decrypted;
    } catch (e) {
      debugPrint("❌ DECRYPT ERROR: $e");
      return "[Decryption failed]";
    }
  }

  @override
  void dispose() {
    _messageController.dispose();
    _decryptedCache.clear();
    super.dispose();
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
                        return Center(
                          child: Text("Error: ${snapshot.error}"),
                        );
                      }

                      if (!snapshot.hasData) {
                        return const Center(
                          child: CircularProgressIndicator(),
                        );
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

                          return FutureBuilder<String>(
                            future: _getDecryptedMessage(doc),
                            builder: (context, textSnapshot) {
                              if (!textSnapshot.hasData) {
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

                              return Align(
                                alignment: isMine
                                    ? Alignment.centerRight
                                    : Alignment.centerLeft,
                                child: Container(
                                  margin: const EdgeInsets.only(bottom: 8),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 10,
                                  ),
                                  constraints: BoxConstraints(
                                    maxWidth:
                                        MediaQuery.of(context).size.width * 0.7,
                                  ),
                                  decoration: BoxDecoration(
                                    color: isMine
                                        ? Colors.green.shade400
                                        : Colors.grey.shade300,
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  child: Text(
                                    textSnapshot.data!,
                                    style: TextStyle(
                                      color: isMine
                                          ? Colors.white
                                          : Colors.black87,
                                      fontSize: 15,
                                    ),
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
                  icon: const Icon(Icons.add_circle, color: Colors.blue, size: 28),
                  onPressed: () {
                    // Navigate to your other page
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (context) => UploadPage()),
                    );
                  },
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
            )
          ),
        ],
      ),
    );
  }
}
