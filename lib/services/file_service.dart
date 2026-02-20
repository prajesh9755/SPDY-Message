import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:cryptography/cryptography.dart';
import 'crypto_service.dart';

/// Service for picking and encrypting files (PDFs, images, etc.)
class FileService {
  /// Pick a file and encrypt it with the shared key
  /// Returns: Map with encrypted file data, metadata, and crypto params
  static Future<Map<String, dynamic>?> pickAndEncryptFile(
    SecretKey sharedKey,
  ) async {
    try {
      // Pick file
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf', 'jpg', 'jpeg', 'png', 'doc', 'docx'],
      );

      if (result == null || result.files.single.path == null) {
        return null;
      }

      final file = result.files.single;
      final fileBytes = await file.bytes;

      if (fileBytes == null) {
        throw Exception("Could not read file");
      }

      // Encrypt the file
      final encrypted = await CryptoService.encryptFile(
        Uint8List.fromList(fileBytes),
        sharedKey,
      );

      return {
        'fileName': file.name,
        'fileSize': fileBytes.length,
        'fileExtension': file.extension,
        'encryptedData': encrypted['data'], // Uint8List
        'nonce': encrypted['nonce'], // Base64 string
        'mac': encrypted['mac'], // Base64 string
      };
    } catch (e) {
      print("❌ FILE ENCRYPTION ERROR: $e");
      rethrow;
    }
  }

  /// Decrypt file bytes
  static Future<Uint8List> decryptFile(
    Uint8List encryptedData,
    String nonce,
    String mac,
    SecretKey sharedKey,
  ) async {
    return CryptoService.decryptFile(
      encryptedData,
      nonce,
      mac,
      sharedKey,
    );
  }
}
