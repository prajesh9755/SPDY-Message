import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:spdy_message/services/auth_service.dart';
import 'chat_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {

  final Map<String, String> _decryptedCache = {};

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("SpdyMessage"),
        backgroundColor: Colors.green,
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: "Logout",
            onPressed: () => _showLogoutWarning(context),
          ),
        ],
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('chats')
            .where('participants',
                arrayContains: FirebaseAuth.instance.currentUser?.uid)
            .orderBy('timestamp', descending: true)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text("Error: ${snapshot.error}"));
          }

          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final chats = snapshot.data!.docs;

          if (chats.isEmpty) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.chat_bubble_outline, size: 64, color: Colors.grey),
                  SizedBox(height: 16),
                  Text(
                    "No chats yet",
                    style: TextStyle(fontSize: 18, color: Colors.grey),
                  ),
                  SizedBox(height: 8),
                  Text(
                    "Tap + to start a new conversation",
                    style: TextStyle(color: Colors.grey),
                  ),
                ],
              ),
            );
          }

            // return ListView.builder(
            //   itemCount: chats.length,
            //   itemBuilder: (context, index) {
            //     final chat = chats[index];
            //     final participants = List<String>.from(chat['participants']);
            //     final currentUserId = FirebaseAuth.instance.currentUser!.uid;
            //     final recipientId =
            //         participants.firstWhere((id) => id != currentUserId);

            //     return Card(
            //       margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            //       child: ListTile(
            //         leading: CircleAvatar(
            //           backgroundColor: Colors.green,
            //           child: const Icon(Icons.person, color: Colors.white),
            //         ),
            //         title: Text(
            //           chat['chatName'] ?? "Unknown",
            //           style: const TextStyle(fontWeight: FontWeight.bold),
            //         ),
            //         subtitle: const Text("Tap to open secure chat"),
            //         trailing: const Icon(Icons.lock, color: Colors.green, size: 20),
            //         onTap: () => _openChat(chat.id, recipientId),
            //       ),
            //     );
            //   },
            // );

            return ListView.builder(
              itemCount: chats.length,
              itemBuilder: (context, index) {
                final chat = chats[index];
                final participants = List<String>.from(chat['participants']);
                final currentUserId = FirebaseAuth.instance.currentUser!.uid;
                
                // 🔥 This correctly identifies the OTHER person
                final recipientId = participants.firstWhere((id) => id != currentUserId);

                return FutureBuilder<DocumentSnapshot>(
                  // 🔥 Fetch the other user's profile
                  future: FirebaseFirestore.instance.collection('users').doc(recipientId).get(),
                  builder: (context, snapshot) {
                    String displayName = "Loading...";
                    String? otherPublicKey;

                    if (snapshot.hasData && snapshot.data!.exists) {
                      final data = snapshot.data!.data() as Map<String, dynamic>;
                      displayName = data['phoneNumber'] ?? "Unknown User"; // 🔥 Show real number
                      otherPublicKey = data['publicKey']; // Grab this for the next screen
                    }

                    return Card(
                      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      child: ListTile(
                        leading: const CircleAvatar(
                          backgroundColor: Colors.green,
                          child: Icon(Icons.person, color: Colors.white),
                        ),
                        title: Text(
                          displayName, // 🔥 Now shows the Recipient's Number
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        subtitle: const Text("Tap to open secure chat"),
                        trailing: const Icon(Icons.lock, color: Colors.green, size: 20),
                        // onTap: () {
                        //   if (otherPublicKey != null) {
                        //     // 🔥 Pass the Public Key to ChatScreen for Encryption
                        //     _openChat(
                        //       chat.id, 
                        //       otherPublicKey!
                        //     );
                        //   }
                        // },
                        onTap: () {
                          if (otherPublicKey != null) {
                            // 🔥 Pass BOTH: the ID for Firestore and the Key for Encryption
                            _openChat(
                              chatId: chat.id, 
                              recipientId: recipientId, // The short UID (e.g., R4EOa...)
                              recipientPublicKey: otherPublicKey, // The long key string
                            );
                          }
                        },
                      ),
                    );
                  },
                );
              },
            );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showNewChatDialog,
        backgroundColor: Colors.green,
        child: const Icon(Icons.add_comment),
      ),
    );
  }
  
  void _showLogoutWarning(BuildContext context) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text("Logout"),
          content: const Text("Are you sure you want to logout?"),
          actions: [
            // Cancel Button
            TextButton(
              onPressed: () => Navigator.pop(context), 
              child: const Text("Cancel"),
            ),
            // Confirm Button
            TextButton(
              onPressed: () async {
                Navigator.pop(context); // Close dialog
                await FirebaseAuth.instance.signOut();
                AuthService.clearSession(); // Clear static ID
                // Navigator.pushReplacementNamed(context, '/login');
              },
              child: const Text("Logout", style: TextStyle(color: Colors.red)),
            ),
          ],
        );
      },
    );
  }

  
  /// Open chat with end-to-end encryption
  // Future<void> _openChat(String chatId, String otherUserId) async {
  //   try {
  //     // Fetch other user's public key from Firestore
  //     final userDoc = await FirebaseFirestore.instance
  //         .collection('users')
  //         .doc(otherUserId)
  //         .get();

  //     if (!userDoc.exists || userDoc.data()?['publicKey'] == null) {
  //       if (mounted) {
  //         ScaffoldMessenger.of(context).showSnackBar(
  //           const SnackBar(
  //             content: Text("User's encryption key not found. They need to login again."),
  //           ),
  //         );
  //       }
  //       return;
  //     }

  //     final otherUserPublicKey = userDoc['publicKey'] as String;

  //     // Navigate to chat screen
  //     if (mounted) {
  //       Navigator.push(
  //         context,
  //         MaterialPageRoute(
  //           builder: (_) => ChatScreen(
  //             chatId: chatId,
  //             otherUserPublicKey: otherUserPublicKey,
  //           ),
  //         ),
  //       );
  //     }
  //   } catch (e) {
  //     debugPrint("❌ OPEN CHAT ERROR: $e");
  //     if (mounted) {
  //       ScaffoldMessenger.of(context).showSnackBar(
  //         const SnackBar(content: Text("Failed to open chat")),
  //       );
  //     }
  //   }
  // }

  void _openChat({
      required String chatId, 
      required String recipientId, 
      required String recipientPublicKey
    }) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => ChatScreen(
            chatId: chatId,
            recipientId: recipientId, // Used for fetching keys/profile
            otherUserPublicKey: recipientPublicKey, // Used for encryption
          ),
        ),
      );
    }

  /// Show dialog to create new chat
  void _showNewChatDialog() {
    final phoneController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("New Secure Chat"),
        content: TextField(
          controller: phoneController,
          maxLength: 10,
          keyboardType: TextInputType.phone,
          decoration: const InputDecoration(
            hintText: "Enter 10-digit number",
            prefixText: "+91 ",
            prefixStyle: TextStyle(fontWeight: FontWeight.bold),
            counterText: "",
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Cancel"),
          ),
          ElevatedButton(
            onPressed: () {
              if (phoneController.text.trim().length == 10) {
                _createNewChat("+91${phoneController.text.trim()}");
                Navigator.pop(context);
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
            child: const Text("Start Chat"),
          ),
        ],
      ),
    );
  }

  /// Create new chat if user exists
  Future<void> _createNewChat(String targetPhone) async {
    try {
      final currentUser = FirebaseAuth.instance.currentUser!;

      // Find user by phone number
      final userQuery = await FirebaseFirestore.instance
          .collection('users')
          .where('phoneNumber', isEqualTo: targetPhone)
          .get();

      if (userQuery.docs.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("User not found with this number")),
          );
        }
        return;
      }

      final targetUserId = userQuery.docs.first.id;

      // Prevent self-chat
      if (targetUserId == currentUser.uid) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("You cannot chat with yourself")),
          );
        }
        return;
      }

      // Check if chat already exists
      final existingChats = await FirebaseFirestore.instance
          .collection('chats')
          .where('participants', arrayContains: currentUser.uid)
          .get();

      final chatExists = existingChats.docs.any((doc) {
        final participants = List<String>.from(doc['participants']);
        return participants.contains(targetUserId);
      });

      if (chatExists) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Chat already exists with this user")),
          );
        }
        return;
      }

      // Create new chat
      await FirebaseFirestore.instance.collection('chats').add({
        'participants': [currentUser.uid, targetUserId],
        'chatName': targetPhone,
        'lastMessage': "",
        'timestamp': FieldValue.serverTimestamp(),
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Chat created successfully!")),
        );
      }
    } catch (e) {
      debugPrint("❌ CREATE CHAT ERROR: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Failed to create chat")),
        );
      }
    }
  }
}
