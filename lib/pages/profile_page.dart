import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'login_page.dart';

class ProfilePage extends StatefulWidget {
  final bool isDarkMode;

  const ProfilePage({super.key, required this.isDarkMode});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final supabase = Supabase.instance.client;

  String username = '';
  bool isLoading = true;

  @override
  void initState() {
    super.initState();
    loadUserData();
  }

  Future<void> loadUserData() async {
    final user = supabase.auth.currentUser;

    if (user == null) return;

    final response = await supabase
        .from('users')
        .select('username')
        .eq('id', user.id)
        .maybeSingle();

    if (!mounted) return;

    setState(() {
      username = response != null ? response['username'] : '';
      isLoading = false;
    });
  }

  Future<void> logout() async {
    try {
      await supabase.auth.signOut();

      if (!mounted) return;

      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginPage()),
        (route) => false,
      );
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("Logout failed: $e")));
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = supabase.auth.currentUser;

    return Scaffold(
      backgroundColor: widget.isDarkMode ? Colors.grey[900] : Colors.grey[100],

      appBar: AppBar(
        elevation: 1,
        backgroundColor: widget.isDarkMode ? Colors.black : Colors.white,

        iconTheme: IconThemeData(
          color: widget.isDarkMode ? Colors.white : Colors.black,
        ),

        title: Text(
          "Profile",
          style: TextStyle(
            color: widget.isDarkMode ? Colors.white : Colors.black,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),

      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  CircleAvatar(
                    radius: 50,
                    backgroundColor: Colors.blue,
                    child: Text(
                      username.isNotEmpty ? username[0].toUpperCase() : '',
                      style: const TextStyle(fontSize: 40, color: Colors.white),
                    ),
                  ),

                  const SizedBox(height: 20),

                  Text(
                    username,
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: widget.isDarkMode ? Colors.white : Colors.black,
                    ),
                  ),

                  const SizedBox(height: 10),

                  Text(
                    user?.email ?? '',
                    style: TextStyle(
                      fontSize: 18,
                      color: widget.isDarkMode
                          ? Colors.grey[400]
                          : Colors.grey[700],
                    ),
                  ),

                  const SizedBox(height: 30),

                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              "Change password feature coming soon",
                            ),
                          ),
                        );
                      },
                      child: const Text("Change Password"),
                    ),
                  ),

                  const SizedBox(height: 15),

                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: logout,
                      icon: const Icon(Icons.logout),
                      label: const Text("Logout"),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}
