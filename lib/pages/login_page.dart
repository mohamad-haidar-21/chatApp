import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/crypto_service.dart';
import '../services/key_manager.dart';
import '../services/key_storage.dart';
import 'home_page.dart';
import 'signup_page.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final usernameController = TextEditingController();
  final passwordController = TextEditingController();
  final supabase = Supabase.instance.client;

  bool isLoading = false;

  Future<void> login() async {
    final username = usernameController.text.trim();
    final password = passwordController.text.trim();

    if (username.isEmpty || password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Please enter username and password")),
      );
      return;
    }

    setState(() => isLoading = true);

    try {
      // Step 1: Get the email associated with this username
      final userQuery = await supabase
          .from('users')
          .select('email')
          .eq('username', username)
          .maybeSingle();

      if (userQuery == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Username not found")),
          );
        }
        setState(() => isLoading = false);
        return;
      }

      final email = userQuery['email'];

      // Step 2: Sign in with email and password
      final response = await supabase.auth.signInWithPassword(
        email: email,
        password: password,
      );
      if (response.user != null) {
        await initializeEncryptionKeys();

        if (mounted) {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (_) => const HomePage()),
          );
        }
      }
    } on AuthException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Login failed: ${e.message}")),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Error: $e")),
        );
      }
    }

    setState(() => isLoading = false);
  }
  Future<void> initializeEncryptionKeys() async {
    final cryptoService = CryptoService();
    final storage = KeyStorage();

    final currentUser = supabase.auth.currentUser;

    if (currentUser == null) {
      debugPrint("No logged user");
      return;
    }


    final localPrivateKey = await storage.getPrivateKey();
    final localPublicKey = await storage.getPublicKey();


    // Check if user already has public key in database
    final userData = await supabase
        .from('users')
        .select('public_key')
        .eq('id', currentUser.id)
        .single();


    final databasePublicKey = userData['public_key'];


    debugPrint("Local public key: $localPublicKey");
    debugPrint("Database public key: $databasePublicKey");


    // Case 1: Everything exists
    if (localPrivateKey != null &&
        localPublicKey != null &&
        databasePublicKey != null) {

      debugPrint("Keys already synchronized");
      return;
    }


    // Case 2: Local keys exist but database missing public key
    if (localPublicKey != null && localPrivateKey != null) {

      await supabase
          .from('users')
          .update({
        'public_key': localPublicKey,
      })
          .eq('id', currentUser.id);


      debugPrint("Uploaded existing public key");
      return;
    }


    // Case 3: Generate new keys
    final keyPair = await cryptoService.generateKeyPair();


    final publicKey =
    await cryptoService.getPublicKey(keyPair);

    final privateKey =
    await cryptoService.getPrivateKey(keyPair);


    await storage.savePrivateKey(privateKey);
    await storage.savePublicKey(publicKey);


    await supabase
        .from('users')
        .update({
      'public_key': publicKey,
    })
        .eq('id', currentUser.id);


    debugPrint("New encryption keys created");
  }
  @override
  void dispose() {
    usernameController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[100],
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              // App logo / title
              const Icon(
                Icons.chat_bubble_rounded,
                size: 85,
                color: Colors.blue,
              ),
              const SizedBox(height: 10),
              Text(
                "Welcome Back",
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey[800],
                ),
              ),
              Text(
                "Login to continue",
                style: TextStyle(
                  fontSize: 16,
                  color: Colors.grey[600],
                ),
              ),
              const SizedBox(height: 40),

              // Username field (changed from email)
              TextField(
                controller: usernameController,
                decoration: InputDecoration(
                  labelText: "Username",
                  prefixIcon: const Icon(Icons.person),
                  filled: true,
                  fillColor: Colors.white,
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 18, vertical: 18),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Colors.grey.shade300),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Password field
              TextField(
                controller: passwordController,
                decoration: InputDecoration(
                  labelText: "Password",
                  prefixIcon: const Icon(Icons.lock),
                  filled: true,
                  fillColor: Colors.white,
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 18, vertical: 18),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Colors.grey.shade300),
                  ),
                ),
                obscureText: true,
                onSubmitted: (_) => login(),
              ),
              const SizedBox(height: 25),

              // Login button
              SizedBox(
                width: double.infinity,
                height: 55,
                child: ElevatedButton(
                  onPressed: isLoading ? null : login,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    elevation: 2,
                  ),
                  child: isLoading
                      ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 2,
                    ),
                  )
                      : const Text(
                    "Login",
                    style: TextStyle(fontSize: 18),
                  ),
                ),
              ),

              const SizedBox(height: 20),

              // Sign up link
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text("Don't have an account?  "),
                  GestureDetector(
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const SignupPage()),
                      );
                    },
                    child: const Text(
                      "Create Account",
                      style: TextStyle(
                        color: Colors.blue,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  )
                ],
              )
            ],
          ),
        ),
      ),
    );
  }
}