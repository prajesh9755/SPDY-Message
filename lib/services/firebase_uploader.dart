import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cryptography/cryptography.dart';
import 'package:spdy_message/services/crypto_service.dart';

/// Uploads files to Firebase Storage under the user's phone number path.
/// Path structure: user_data/{phoneNumber}/{file_name}
Future<Map<String, dynamic>> uploadUserFiles(
  List<PlatformFile> files,
  String phoneNumber, {
  required Function(int count) onFileCompleted,
}) async {
  if (files.isEmpty) {
    return {'success': false, 'message': 'No files selected.'};
  }

  final storage = FirebaseStorage.instance;
  int uploadedCount = 0;

  await Future.wait(
    files.map((file) async {
      if (file.path == null) return;

      try {
        final ref = storage.ref().child('user_data/$phoneNumber/${file.name}');

        final File fileToUpload = File(file.path!);
        await ref.putFile(fileToUpload);

        uploadedCount++;
        onFileCompleted(uploadedCount);
      } on FirebaseException catch (e) {
        print('Firebase Error: ${e.code}');
      } catch (e) {
        print('Error: $e');
      }
    }),
  );

  if (uploadedCount > 0) {
    return {
      'success': true,
      'message': 'Uploaded $uploadedCount of ${files.length} files.',
    };
  } else {
    return {'success': false, 'message': 'Upload failed.'};
  }
}

Future<Map<String, dynamic>> uploadChatFiles(
  List<PlatformFile> files,
  String chatId,
  SecretKey sharedKey, {
  required Function(int count) onFileCompleted,
}) async {
  if (files.isEmpty) {
    return {'success': false, 'message': 'No files selected.'};
  }

  final storage = FirebaseStorage.instance;
  final firestore = FirebaseFirestore.instance;
  final uid = FirebaseAuth.instance.currentUser!.uid;
  int uploadedCount = 0;

  await Future.wait(
    files.map((file) async {
      if (file.path == null) return;

      try {
        final File fileToUpload = File(file.path!);
        final bytes = await fileToUpload.readAsBytes();

        // 1. Encrypt File Bytes
        final encryptedData = await CryptoService.encryptFile(bytes, sharedKey);
        final cipherText = encryptedData['data'] as List<int>;
        final fileNonce = encryptedData['nonce'] as String;
        final fileMac = encryptedData['mac'] as String;

        // 2. Upload Encrypted Data
        final ext = file.extension?.toLowerCase() ?? '';
        String type = 'image';
        if (ext == 'pdf')
          type = 'pdf';
        else if (['mp4', 'mov', 'avi', 'mkv', 'flv', 'wmv'].contains(ext))
          type = 'video';
        final fileName =
            '${DateTime.now().millisecondsSinceEpoch}_${file.name}';

        final ref = storage.ref().child('chats/$chatId/$fileName');
        final snapshot = await ref.putData(
          Uint8List.fromList(cipherText),
          SettableMetadata(
            contentType: 'application/octet-stream', // Because it's encrypted
          ),
        );

        final url = await snapshot.ref.getDownloadURL();

        // 3. Encrypt Metadata Payload (JSON)
        final payload = jsonEncode({
          "url": url,
          "name": file.name,
          "fileNonce": fileNonce,
          "fileMac": fileMac,
          "size": file.size,
        });
        final encryptedPayload = await CryptoService.encryptText(
          payload,
          sharedKey,
        );

        // 4. Save Message to Firestore
        final batch = firestore.batch();
        final messageRef = firestore
            .collection('chats')
            .doc(chatId)
            .collection('messages')
            .doc();

        batch.set(messageRef, {
          'sender': uid,
          'cipher': encryptedPayload['cipher'],
          'nonce': encryptedPayload['nonce'],
          'mac': encryptedPayload['mac'],
          'type': type,
          'timestamp': FieldValue.serverTimestamp(),
        });

        final chatRef = firestore.collection('chats').doc(chatId);
        batch.update(chatRef, {
          'lastMessageTimestamp': FieldValue.serverTimestamp(),
          'lastMessage': "[Encrypted File]",
        });

        await batch.commit();

        uploadedCount++;
        onFileCompleted(uploadedCount);
      } catch (e) {
        print('Error: $e');
      }
    }),
  );

  if (uploadedCount > 0) {
    return {
      'success': true,
      'message': 'Uploaded $uploadedCount of ${files.length} files.',
    };
  } else {
    return {'success': false, 'message': 'Upload failed.'};
  }
}
