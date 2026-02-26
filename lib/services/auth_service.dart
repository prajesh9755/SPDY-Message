import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart'; 
import 'crypto_service.dart';

class AuthService {
  final _auth = FirebaseAuth.instance;
  static String? _staticVerificationId;
  final _db = FirebaseFirestore.instance;

  static void clearSession() {
    _staticVerificationId = null;
  }

  // Unified helper to handle Firestore logic
  Future<void> _syncUserToFirestore(User user) async {
    final userDocRef = _db.collection('users').doc(user.uid);
    final userDoc = await userDocRef.get();

    if (!userDoc.exists || userDoc.data()?['publicKey'] == null) {
      final publicKey = await CryptoService.generateIdentityKey();
      
      await userDocRef.set({
        'uid': user.uid,
        'phoneNumber': user.phoneNumber,
        'publicKey': publicKey,
        'createdAt': FieldValue.serverTimestamp(),
        'lastLogin': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      
      print("✅ ###################User created in Firestore: ${user.uid}");
    } else {
      // Just update the last login if user exists
      await userDocRef.update({
        'lastLogin': FieldValue.serverTimestamp(),
      });
      print("✅ ######################User already exists in Firestore: ${user.uid}");
    }
  }

  Future<void> sendOTP({required String phone, required Function() onSent, required Function(String) onFailed}) async {
    await _auth.verifyPhoneNumber(
      phoneNumber: phone,
      verificationCompleted: (PhoneAuthCredential credential) async {
        final userCredential = await _auth.signInWithCredential(credential);
        if (userCredential.user != null) {
          await _syncUserToFirestore(userCredential.user!);
        }
      },
      codeSent: (verificationId, resendToken) {
        _staticVerificationId = verificationId;
        onSent();
      },
      verificationFailed: (e) => onFailed(e.message ?? "Error"),
      codeAutoRetrievalTimeout: (id) => _staticVerificationId = id,
    );
  }
  
  Future<void> verifyOTP(String smsCode) async {
    if (_staticVerificationId == null) {
      throw Exception('Verification ID missing. Try sending OTP again.');
    }
    
    final credential = PhoneAuthProvider.credential(
      verificationId: _staticVerificationId!,
      smsCode: smsCode,
    );

    // 🔥 FIX: Sign in ONCE and capture the user
    final userCredential = await _auth.signInWithCredential(credential);
    final user = userCredential.user;

    if (user != null) {
      await _syncUserToFirestore(user);
    }
  }
}