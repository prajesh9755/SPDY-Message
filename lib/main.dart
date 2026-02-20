import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:spdy_message/screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'services/crypto_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Firebase
  await Firebase.initializeApp();

  // Initialize crypto service
  await CryptoService.init();

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: StreamBuilder<User?>(
        stream: FirebaseAuth.instance.authStateChanges(), // 🔥 Listens for login/logout
        builder: (context, snapshot) {
          // 1. While checking if user is logged in, show a loader
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Scaffold(body: Center(child: CircularProgressIndicator()));
          }

          // 2. If user exists, go straight to Home
          if (snapshot.hasData) {
            return const HomeScreen();
          }

          // 3. Otherwise, show the Login page
          return const AuthScreen();
        },
      ),
      routes: {
        '/login': (context) => const AuthScreen(),
        '/home': (context) => const HomeScreen(),
      },
    );
  }
}
