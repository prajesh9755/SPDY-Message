import 'dart:async';
import 'package:flutter/material.dart';
import '../services/auth_service.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _phoneController = TextEditingController();
  final _otpController = TextEditingController();

  bool _isOTPSent = false;
  bool _isLoading = false;
  int _secondsRemaining = 0;
  Timer? _resendTimer;

  @override
  void dispose() {
    _phoneController.dispose();
    _otpController.dispose();
    _resendTimer?.cancel();
    super.dispose();
  }
  

  void _startResendTimer() {
    _resendTimer?.cancel(); // Clear any old timer
    setState(() => _secondsRemaining = 60);
    _resendTimer?.cancel();

    _resendTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_secondsRemaining == 0) {
        timer.cancel();
      } else {
        setState(() => _secondsRemaining--);
      }
    });
  }

  // Future<void> _sendOTP() async {
  //   final phone = _phoneController.text.trim();

  //   if (phone.length != 10) {
  //     _showError("Please enter a valid 10-digit number");
  //     return;
  //   }

  //   final fullPhone = "+91$phone";
  //   setState(() => _isLoading = true);

  //   try {
  //     await _authService.sendOTP(fullPhone, () {
  //       if (mounted) {
  //         setState(() {
  //           _isOTPSent = true;
  //           _isLoading = false;
  //         });
  //         _startResendTimer();
  //       }
  //     });
  //   } catch (e) {
  //     if (mounted) {
  //       setState(() => _isLoading = false);
  //       _showError(e.toString().replaceAll("Exception: ", ""));
  //     }
  //   }
  // }

void _sendOTP() async {

  print("#################################Attempting to send OTP to: ${_phoneController.text}"); // Debug line
  AuthService.clearSession();
  setState(() => _isLoading = true);

  // Manual safety timeout
  Future.delayed(const Duration(seconds: 15), () {
    if (mounted && _isLoading && !_isOTPSent) {
      // 🔥 Wrap these in { }
      setState(() {
        _isLoading = false;
      });
      _showErrorSnackBar("Request timed out. Please try again.");
    }
  });

  await AuthService().sendOTP(
    phone: "+91${_phoneController.text}",
    onSent: () {
      if (mounted) {
        // 🔥 Wrap this in { }
        setState(() {
          _isOTPSent = true;
          _isLoading = false;
        });
        _startResendTimer(); // 🔥 Trigger the countdown here!
      }
    },
    onFailed: (errorMessage) {
      if (mounted) {
        // 🔥 Wrap this in { }
        setState(() {
          _isLoading = false;
        });
        _showErrorSnackBar(errorMessage);
      }
    },
  );
}

  void _showErrorSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
      ),
    );
  }

  // Future<void> _verifyOTP() async {
  //   final otp = _otpController.text.trim();

  //   if (otp.length != 6) {
  //     _showError("Please enter a valid 6-digit OTP");
  //     return;
  //   }

  //   if (_verificationId == null) {
  //     print("####################################Debug Info: ID is null. OTP Sent was: $_isOTPSent");
  //     return;
  //   }

  //   setState(() => _isLoading = true);

  //   try {
  //     await _authService.verifyOTP(otp);

  //     if (mounted) {
  //       Navigator.pushReplacement(
  //         context,
  //         MaterialPageRoute(builder: (_) => const HomeScreen()),
  //       );
  //     }
  //   } catch (e) {
  //     if (mounted) {
  //       setState(() => _isLoading = false);
  //       _showError(e.toString().replaceAll("Exception: ", ""));
  //     }
  //   }
  // }

  Future<void> _verifyOTP() async {
    setState(() => _isLoading = true);
    try {
      await AuthService().verifyOTP(_otpController.text);
      // Success! The StreamBuilder in main.dart will take over now.
    } catch (e) {
      setState(() => _isLoading = false);
      _showErrorSnackBar(e.toString().replaceAll('Exception: ', ''));
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
      ),
    );
  }

  @override
Widget build(BuildContext context) {
  return Scaffold(
    body: SafeArea(
      child: LayoutBuilder( // 🔥 Added to measure available screen height
        builder: (context, constraints) {
          return SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox( // 🔥 Added to force centering
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: IntrinsicHeight( // 🔥 Ensures Column doesn't stretch weirdly
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center, // 🔥 Your content is centered again!
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // --- I HAVEN'T TOUCHED ANY OF YOUR REMAINING CODE BELOW ---
                    const Icon(
                      Icons.lock,
                      size: 80,
                      color: Colors.green,
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      "SpdyMessage",
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.bold,
                        color: Colors.green,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      "Secure End-to-End Encrypted Chat",
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey,
                      ),
                    ),
                    const SizedBox(height: 48),

                    // Phone Number Input
                    TextField(
                      controller: _phoneController,
                      enabled: !_isOTPSent,
                      keyboardType: TextInputType.phone,
                      maxLength: 10,
                      decoration: InputDecoration(
                        labelText: "Phone Number",
                        prefixText: "+91 ",
                        prefixStyle: const TextStyle(
                          color: Colors.black,
                          fontWeight: FontWeight.bold,
                        ),
                        counterText: "",
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: Colors.green, width: 2),
                        ),
                      ),
                    ),

                    // OTP Input (shown after OTP is sent)
                    if (_isOTPSent) ...[
                      const SizedBox(height: 20),
                      TextField(
                        controller: _otpController,
                        keyboardType: TextInputType.number,
                        maxLength: 6,
                        decoration: InputDecoration(
                          labelText: "Enter OTP",
                          counterText: "",
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide:
                                const BorderSide(color: Colors.green, width: 2),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextButton(
                        onPressed: _secondsRemaining == 0 && !_isLoading
                            ? _sendOTP
                            : null,
                        child: Text(
                          _secondsRemaining == 0
                              ? "Resend OTP"
                              : "Resend in ${_secondsRemaining}s",
                          style: TextStyle(
                            color: _secondsRemaining == 0
                                ? Colors.green
                                : Colors.grey,
                          ),
                        ),
                      ),
                    ],

                    const SizedBox(height: 24),

                    // Submit Button
                    SizedBox(
                      height: 50,
                      child: ElevatedButton(
                        onPressed: _isLoading
                            ? null
                            : (_isOTPSent ? _verifyOTP : _sendOTP),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: _isLoading
                            ? const SizedBox(
                                height: 24,
                                width: 24,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : Text(
                                _isOTPSent ? "Verify & Login" : "Get OTP",
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                      ),
                    ),
                    // --- END OF YOUR UNTOUCHED CODE ---
                  ],
                ),
              ),
            ),
          );
        },
      ),
    ),
  );
}
}
