import 'dart:io';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// Uploads files to Firebase Storage under the user's phone number path.
/// Path structure: user_data/{phoneNumber}/{file_name}
Future<Map<String, dynamic>> uploadUserFiles(
    List<PlatformFile> files,
    String phoneNumber, // 🔥 Changed from userEmail
    {required Function(int count) onFileCompleted}
) async {
    if (files.isEmpty) {
        return {'success': false, 'message': 'No files selected.'};
    }

    final storage = FirebaseStorage.instance;
    int uploadedCount = 0;

    await Future.wait(files.map((file) async {
        if (file.path == null) return;

        try {
            // ✅ Path now uses phone number
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
    }));

    if (uploadedCount > 0) {
        return {
            'success': true, 
            'message': 'Uploaded $uploadedCount of ${files.length} files.'
        };
    } else {
        return {'success': false, 'message': 'Upload failed.'};
    }
}