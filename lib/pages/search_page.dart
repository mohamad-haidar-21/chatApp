import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'chat_page.dart'; // Add this import

class SearchUsersPage extends StatefulWidget {
  const SearchUsersPage({super.key});

  @override
  State<SearchUsersPage> createState() => _SearchUsersPageState();
}

class _SearchUsersPageState extends State<SearchUsersPage> {
  final supabase = Supabase.instance.client;
  final searchController = TextEditingController();

  List<dynamic> searchResults = [];
  bool isSearching = false;
  bool hasSearched = false;

  @override
  void dispose() {
    searchController.dispose();
    super.dispose();
  }

  Future<void> searchUsers(String username) async {
    if (username.trim().isEmpty) {
      setState(() {
        searchResults = [];
        hasSearched = false;
      });
      return;
    }

    setState(() {
      isSearching = true;
      hasSearched = true;
    });

    try {
      final currentUserId = supabase.auth.currentUser!.id;

      // Search for users by username (case-insensitive)
      final results = await supabase
          .from('users')
          .select()
          .ilike('username', '%$username%')
          .neq('id', currentUserId); // Exclude current user

      setState(() {
        searchResults = results;
        isSearching = false;
      });
    } catch (e) {
      setState(() {
        isSearching = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error searching users: $e')),
        );
      }
    }
  }

  Future<void> startChat(dynamic user) async {
    try {
      // Navigate directly to chat page
      if (mounted) {
        Navigator.pop(context); // Close search page
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ChatPage(
              otherUserId: user['id'],
              otherUsername: user['username'],
              chatRoomId: 'id', isDarkMode: false,
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error starting chat: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Search Users'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: TextField(
              controller: searchController,
              decoration: InputDecoration(
                hintText: 'Search by username...',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: searchController.text.isNotEmpty
                    ? IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: () {
                    searchController.clear();
                    searchUsers('');
                  },
                )
                    : null,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onChanged: (value) {
                setState(() {}); // Update UI for clear button
                searchUsers(value);
              },
            ),
          ),
          Expanded(
            child: isSearching
                ? const Center(child: CircularProgressIndicator())
                : !hasSearched
                ? const Center(
              child: Text(
                'Search for users by username',
                style: TextStyle(fontSize: 16, color: Colors.grey),
              ),
            )
                : searchResults.isEmpty
                ? const Center(
              child: Text(
                'No users found',
                style: TextStyle(fontSize: 16, color: Colors.grey),
              ),
            )
                : ListView.builder(
              itemCount: searchResults.length,
              itemBuilder: (context, index) {
                final user = searchResults[index];
                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor: Colors.blue,
                    child: Text(
                      user['username'][0].toUpperCase(),
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                  title: Text(user['username']),
                    subtitle: const Text(
                      "Tap to start chat",
                      style: TextStyle(color: Colors.grey),
                    ),
                  trailing: ElevatedButton(
                    onPressed: () => startChat(user),
                    child: const Text('Chat'),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}