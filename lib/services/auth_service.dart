// import 'package:firebase_auth/firebase_auth.dart';
// import 'package:cloud_firestore/cloud_firestore.dart';
// import 'package:flutter/foundation.dart'; // Added for debugPrint
// import 'crypto_service.dart';

// class AuthService {
//   final _auth = FirebaseAuth.instance;
//   // 🔥 Static variable ensures the ID survives even if the class is re-created
//   static String? _staticVerificationId;

//   final _db = FirebaseFirestore.instance;

//   static void clearSession() {
//     _staticVerificationId = null;
//   }

//   Future<void> _createUserInFirestore(User user) async {
//     final userDoc = _db.collection('users').doc(user.uid);
    
//     // Use set with merge: true to avoid overwriting existing data
//     await userDoc.set({
//       'uid': user.uid,
//       'phoneNumber': user.phoneNumber,
//       'lastLogin': FieldValue.serverTimestamp(),
//     }, SetOptions(merge: true));
//     print("✅ Firestore User Sync Complete");
//   }

//   Future<void> sendOTP({required String phone, required Function() onSent, required Function(String) onFailed}) async {
//     await _auth.verifyPhoneNumber(
//       phoneNumber: phone,
//       //newwwwwwwwwwwwwwwwwwwww
//       verificationCompleted: (PhoneAuthCredential credential) async {
//       final userCredential = await _auth.signInWithCredential(credential);
//       if (userCredential.user != null) {
//         await _createUserInFirestore(userCredential.user!); // ADD THIS
//       }
//     },
//      //newwwwwwwwwwwwwwwwwwwww

//       codeSent: (verificationId, resendToken) {
//         _staticVerificationId = verificationId; // Save it here
//         onSent();
//       },
//       verificationFailed: (e) => onFailed(e.message ?? "Error"),
//       codeAutoRetrievalTimeout: (id) => _staticVerificationId = id,
//       // verificationCompleted: (creds) async => await _auth.signInWithCredential(creds),
//     );
//   }
  
//   Future<void> verifyOTP(String smsCode) async {
//     if (_staticVerificationId == null) {
//       throw Exception('Verification ID missing. Try sending OTP again.');
//     }
//     final credential = PhoneAuthProvider.credential(
//       verificationId: _staticVerificationId!,
//       smsCode: smsCode,
//     );
//     await _auth.signInWithCredential(credential);

//     final userCredential = await _auth.signInWithCredential(credential);
//   final user = userCredential.user;

//   if (user != null) {
//     final userDocRef = _db.collection('users').doc(user.uid);
    
//     // 🔥 1. ALWAYS await the check
//     final userDoc = await userDocRef.get();

//     if (!userDoc.exists || userDoc.data()?['publicKey'] == null) {
//       final publicKey = await CryptoService.generateIdentityKey();
      
//       // 🔥 2. ALWAYS await the write
//       await userDocRef.set({
//         'uid': user.uid,
//         'phoneNumber': user.phoneNumber,
//         'publicKey': publicKey,
//         'createdAt': FieldValue.serverTimestamp(),
//       }, SetOptions(merge: true));
      
//       print("✅ ###################User created in Firestore: ${user.uid}");
//     } else {
//       print("✅ ######################User already exists in Firestore: ${user.uid}");
//     }
//   }
// }
// }

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