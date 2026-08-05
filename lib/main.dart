import 'package:chatapp/pages/login_page.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';


void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
      url: 'https://nnrluhgcioptvlnaonqr.supabase.co',
      anonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im5ucmx1aGdjaW9wdHZsbmFvbnFyIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjQ2NjMwNTAsImV4cCI6MjA4MDIzOTA1MH0.SoyrgneNWhKsnGFRDUIel0EtY9uxvwKfJik-yTuNvwo',
  );

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: LoginPage(),
    );
  }
}