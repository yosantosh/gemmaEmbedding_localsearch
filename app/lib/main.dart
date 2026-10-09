import 'package:flutter/material.dart';

import 'pages/home_page.dart';
import 'theme.dart';

void main() => runApp(const LocalSearchApp());

class LocalSearchApp extends StatelessWidget {
  const LocalSearchApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LocalSearch',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      home: const HomePage(),
    );
  }
}
