import 'package:flutter/material.dart';

class AppColors {
  // Primary Colors - Proper Saffron Theme
  static const Color primaryColor = Color(0xFFFF9933); // Deep Saffron
  static const Color secondaryColor = Color(0xFFFFE5B4); // Misty Saffron
  static const Color primarySaffron = Color(0xFFFF9933); // Deep Saffron
  static const Color lightSaffron = Color(0xFFFFE5B4); // Misty Saffron
  static const Color goldenSaffron = Color(0xFFFFC107); // Golden Saffron
  
  // Secondary Colors
  static const Color successGreen = Color(0xFF4caf50);
  static const Color warningOrange = Color(0xFFff9800);
  static const Color errorRed = Color(0xFFf44336);
  
  // Neutral Colors
  static const Color textPrimary = Color(0xFF2C1810); // Dark brown for text
  static const Color textSecondary = Color(0xFF5D4037); // Medium brown
  static const Color background = Color(0xFFFFE5B4); // Misty Saffron background
  static const Color white = Color(0xFFFFFFFF);
  static const Color black = Color(0xFF000000);
  
  // Watermark Colors
  static const Color watermarkOm = Color(0xFFF0F0F0); // Very light grey
  
  // Gradients
  static const LinearGradient primaryGradient = LinearGradient(
    colors: [white, lightSaffron],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );
  
  static const LinearGradient voiceGradient = LinearGradient(
    colors: [Color(0xFFFFE5B4), Color(0xFFFF9933)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
  
  static const LinearGradient paymentGradient = LinearGradient(
    colors: [Color(0xFFFF9933), Color(0xFFE55A2B)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
}
