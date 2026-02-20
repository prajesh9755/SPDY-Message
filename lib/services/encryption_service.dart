import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class CryptoService {
  static final _storage = FlutterSecureStorage();

  // Algorithms
  static final X25519 _x25519 = X25519();
  static final AesGcm _aesGcm = AesGcm.with256bits();
  static final Hkdf _hkdf =
      Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  // Optional init (kept for architecture cleanliness)
  static Future<void> init() async {}

  // ---------------------------------------------------------------------------
  // IDENTITY KEY (ONE-TIME PER USER)
  // ---------------------------------------------------------------------------
  static Future<String> generateIdentityKey() async {
    final keyPair = await _x25519.newKeyPair();

    final privateKeyBytes =
        await keyPair.extractPrivateKeyBytes();
    final publicKeyBytes =
        (await keyPair.extractPublicKey()).bytes;

    // Store PRIVATE key locally (never goes to Firestore)
    await _storage.write(
      key: 'x25519_private_key',
      value: base64Encode(privateKeyBytes),
    );

    // Return PUBLIC key (store in Firestore)
    return base64Encode(publicKeyBytes);
  }

  static Future<SimpleKeyPair> _getMyKeyPair() async {
    final stored = await _storage.read(key: 'x25519_private_key');
    if (stored == null) {
      throw Exception('Private key missing');
    }

    return _x25519.newKeyPairFromSeed(
      base64Decode(stored),
    );
  }

  // ---------------------------------------------------------------------------
  // SHARED SECRET (PER CHAT)
  // ---------------------------------------------------------------------------
  static Future<SecretKey> deriveSharedKey(
    String otherUserPublicKeyBase64,
  ) async {
    final myKeyPair = await _getMyKeyPair();

    final otherPublicKey = SimplePublicKey(
      base64Decode(otherUserPublicKeyBase64),
      type: KeyPairType.x25519,
    );

    // Diffie-Hellman
    final sharedSecret = await _x25519.sharedSecretKey(
      keyPair: myKeyPair,
      remotePublicKey: otherPublicKey,
    );

    // Derive AES-256 key using HKDF
    return _hkdf.deriveKey(
      secretKey: sharedSecret,
      nonce: utf8.encode('spdy-message-e2ee'),
    );
  }

  // ---------------------------------------------------------------------------
  // TEXT ENCRYPTION
  // ---------------------------------------------------------------------------
  static Future<Map<String, String>> encryptText(
    String text,
    SecretKey key,
  ) async {
    final box = await _aesGcm.encrypt(
      utf8.encode(text),
      secretKey: key,
    );

    return {
      'cipher': base64Encode(box.cipherText),
      'nonce': base64Encode(box.nonce),
      'mac': base64Encode(box.mac.bytes),
    };
  }

  static Future<String> decryptText(
    Map<String, String> data,
    SecretKey key,
  ) async {
    final box = SecretBox(
      base64Decode(data['cipher']!),
      nonce: base64Decode(data['nonce']!),
      mac: Mac(base64Decode(data['mac']!)),
    );

    final plainBytes =
        await _aesGcm.decrypt(box, secretKey: key);

    return utf8.decode(plainBytes);
  }

  // ---------------------------------------------------------------------------
  // FILE ENCRYPTION (IMAGE / VIDEO / DOC)
  // ---------------------------------------------------------------------------
  static Future<Map<String, dynamic>> encryptFile(
    Uint8List bytes,
    SecretKey key,
  ) async {
    final box = await _aesGcm.encrypt(
      bytes,
      secretKey: key,
    );

    return {
      'data': box.cipherText, // upload this to Firebase Storage
      'nonce': base64Encode(box.nonce),
      'mac': base64Encode(box.mac.bytes),
    };
  }

  static Future<Uint8List> decryptFile(
    Uint8List encryptedBytes,
    String nonceBase64,
    String macBase64,
    SecretKey key,
  ) async {
    final box = SecretBox(
      encryptedBytes,
      nonce: base64Decode(nonceBase64),
      mac: Mac(base64Decode(macBase64)),
    );

    return Uint8List.fromList(
      await _aesGcm.decrypt(box, secretKey: key),
    );
  }
}
