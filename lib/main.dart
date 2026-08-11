import 'package:flutter/material.dart';
import 'package:logger/logger.dart';
import 'package:speech_generator/supertonic.dart';

var logger = Logger();

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Speech Generator',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: .fromSeed(
          seedColor: const Color.fromARGB(217, 210, 170, 78),
        ),
      ),
      home: TTSPage(),
    );
  }
}
