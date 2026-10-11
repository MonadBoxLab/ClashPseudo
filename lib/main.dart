import 'package:flutter/material.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Clash Pseudo',
      home: Scaffold(
        appBar: AppBar(title: const Text('Clash Pseudo')),
        body: const Center(child: Text('Hello World')),
      ),
    );
  }
}
