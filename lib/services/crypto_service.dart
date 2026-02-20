import 'dart:convert';
import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cryptography/cryptography.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Unified crypto service using X25519 + AES-GCM
/// Handles identity keys, shared secrets, and encryption/decryption
class CryptoService {
  static const _storage = FlutterSecureStorage();
  
  // Algorithms
  static final _x25519 = X25519();
  static final _aesGcm = AesGcm.with256bits();
  static final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  static Future<void> init() async {
    // Reserved for future initialization if needed
  }

  // ==================== IDENTITY KEY MANAGEMENT ====================
  
  /// Generate a new X25519 key pair (called once per user)
  /// Returns: Base64-encoded public key (store in Firestore)
  /// Stores: Private key in secure storage (NEVER upload to Firebase)
  // static Future<String> generateIdentityKey() async {
  //   final keyPair = await _x25519.newKeyPair();
    
  //   final privateBytes = await keyPair.extractPrivateKeyBytes();
  //   final publicBytes = (await keyPair.extractPublicKey()).bytes;

  //   // Store private key locally
  //   await _storage.write(
  //     key: 'x25519_private',
  //     value: base64Encode(privateBytes),
  //   );

  //   // Return public key for Firestore
  //   return base64Encode(publicBytes);
  // }

// ==================== IDENTITY KEY MANAGEMENT ====================
  
  static Future<String> generateIdentityKey() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) throw Exception("User not logged in");

    final keyPair = await _x25519.newKeyPair();
    final privateBytes = await keyPair.extractPrivateKeyBytes();
    final publicBytes = (await keyPair.extractPublicKey()).bytes;

    // 🔥 Key is now saved with the UID to avoid conflicts
    await _storage.write(
      key: 'x25519_private_$uid',
      value: base64Encode(privateBytes),
    );

    return base64Encode(publicBytes);
  }

  static Future<SimpleKeyPair> _getMyKeyPair() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) throw Exception("User not logged in");

    // 🔥 Read the key specific to this UID
    final storedPrivate = await _storage.read(key: 'x25519_private_$uid');
    
    if (storedPrivate == null) {
      // Auto-generate if missing (e.g., first login or re-install)
      debugPrint("Keys missing for $uid. Regenerating...");
      final newPublic = await generateIdentityKey();
      
      await FirebaseFirestore.instance.collection('users').doc(uid).update({
        'publicKey': newPublic,
      });
      
      return _getMyKeyPair(); // Recursive call to get the new key
    }

    return _x25519.newKeyPairFromSeed(base64Decode(storedPrivate));
  }

  /// Get the user's private key pair from secure storage

  /// Get the user's private key pair from secure storage
// static Future<SimpleKeyPair> _getMyKeyPair() async {
//   final storedPrivate = await _storage.read(key: 'x25519_private');
  
//   if (storedPrivate == null) {
//     // If key is missing, we must generate a new one to prevent the crash
//     debugPrint("Key missing. Generating new X25519 identity...");
//     final newPublicKey = await generateIdentityKey();
    
//     // Update Firestore so the database has your NEW 32-byte key
//     final uid = FirebaseAuth.instance.currentUser?.uid;
//     if (uid != null) {
//       await FirebaseFirestore.instance.collection('users').doc(uid).update({
//         'publicKey': newPublicKey,
//       });
//     }
//     return _getMyKeyPair(); // Recursively call to get the newly created key
//   }

//   return _x25519.newKeyPairFromSeed(base64Decode(storedPrivate));
// }


  // ==================== SHARED SECRET DERIVATION ====================
  
  /// Derive a shared AES key using X25519 Diffie-Hellman
  /// This is done per chat, using the other user's public key
  static Future<SecretKey> deriveSharedKey(String otherPublicBase64) async {
    final myKeyPair = await _getMyKeyPair();
    
    final otherPublic = SimplePublicKey(
      base64Decode(otherPublicBase64),
      type: KeyPairType.x25519,
    );

    // Perform Diffie-Hellman key exchange
    final sharedSecret = await _x25519.sharedSecretKey(
      keyPair: myKeyPair,
      remotePublicKey: otherPublic,
    );

    // Derive AES-256 key using HKDF
    return _hkdf.deriveKey(
      secretKey: sharedSecret,
      nonce: utf8.encode('spdy-e2ee-v1'),
    );
  }

  // ==================== TEXT ENCRYPTION ====================
  
  /// Encrypt a text message
  /// Returns: Map with cipher, nonce, and mac (all Base64)
  static Future<Map<String, String>> encryptText(
    String plaintext,
    SecretKey sharedKey,
  ) async {
    final secretBox = await _aesGcm.encrypt(
      utf8.encode(plaintext),
      secretKey: sharedKey,
    );

    return {
      'cipher': base64Encode(secretBox.cipherText),
      'nonce': base64Encode(secretBox.nonce),
      'mac': base64Encode(secretBox.mac.bytes),
    };
  }

  /// Decrypt a text message
  static Future<String> decryptText(
    Map<String, String> encryptedData,
    SecretKey sharedKey,
  ) async {
    final secretBox = SecretBox(
      base64Decode(encryptedData['cipher']!),
      nonce: base64Decode(encryptedData['nonce']!),
      mac: Mac(base64Decode(encryptedData['mac']!)),
    );

    final plainBytes = await _aesGcm.decrypt(
      secretBox,
      secretKey: sharedKey,
    );

    return utf8.decode(plainBytes);
    
  }

  // ==================== FILE ENCRYPTION ====================
  
  /// Encrypt file bytes (for images, PDFs, etc.)
  /// Returns: Map with encrypted bytes (Uint8List), nonce, and mac
  static Future<Map<String, dynamic>> encryptFile(
    Uint8List fileBytes,
    SecretKey sharedKey,
  ) async {
    final secretBox = await _aesGcm.encrypt(
      fileBytes,
      secretKey: sharedKey,
    );

    return {
      'data': secretBox.cipherText, // Raw bytes (upload to Firebase Storage)
      'nonce': base64Encode(secretBox.nonce),
      'mac': base64Encode(secretBox.mac.bytes),
    };
  }

  /// Decrypt file bytes
  static Future<Uint8List> decryptFile(
    Uint8List encryptedBytes,
    String nonceBase64,
    String macBase64,
    SecretKey sharedKey,
  ) async {
    final secretBox = SecretBox(
      encryptedBytes,
      nonce: base64Decode(nonceBase64),
      mac: Mac(base64Decode(macBase64)),
    );

    final plainBytes = await _aesGcm.decrypt(
      secretBox,
      secretKey: sharedKey,
    );

    return Uint8List.fromList(plainBytes);
  }
}
