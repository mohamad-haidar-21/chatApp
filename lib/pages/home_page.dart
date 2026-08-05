import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'profile_page.dart';
import 'search_page.dart';
import 'chat_page.dart'; // Add this import

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool isDarkMode = false;
  List<dynamic> chatUsers = [];
  bool isLoading = true;
  final supabase = Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    loadChatUsers();
  }

  Future<void> loadChatUsers() async {
    try {
      setState(() => isLoading = true);

      final supabase = Supabase.instance.client;

      // Current user ID
      final String currentUserId = supabase.auth.currentUser!.id;

      // 1️⃣ Fetch chat rooms where current user is a participant
      final List<dynamic> rooms = await supabase
          .from('chat_rooms')
          .select('id, user1, user2')
          .or('user1.eq.$currentUserId,user2.eq.$currentUserId')
          .order('created_at', ascending: false);

      // If user has no chat rooms → stop
      if (rooms.isEmpty) {
        setState(() {
          chatUsers = [];
          isLoading = false;
        });
        return;
      }

      // 2️⃣ Extract IDs of the other users
      final List<String> otherUserIds = rooms
          .map((room) =>
      room['user1'] == currentUserId ? room['user2'] : room['user1'])
          .where((id) => id != null)
          .map((id) => id.toString()) // ensure string list
          .toSet() // remove duplicates
          .toList();

      // If list empty → stop (prevents .in_() error)
      if (otherUserIds.isEmpty) {
        setState(() {
          chatUsers = [];
          isLoading = false;
        });
        return;
      }

      // Debugging:
      debugPrint("🔍 Other user IDs → $otherUserIds");

      // 3️⃣ Fetch user profiles ONLY for these IDs
      final users = await supabase
          .from('users')
          .select()
          .inFilter('id', otherUserIds);

      // 4️⃣ Update UI safely
      setState(() {
        chatUsers = (users is List) ? users : [];
        isLoading = false;
      });
    } catch (e, st) {
      setState(() => isLoading = false);

      // Show clean message to user
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Error loading chats: $e")),
        );
      }

      // Print detailed error for debugging
      debugPrint("❌ loadChatUsers ERROR: $e");
      debugPrint("STACKTRACE: $st");
    }
  }

  void openChat(dynamic user) async {
    final currentUserId = supabase.auth.currentUser!.id;

    // Find existing room
    final room = await supabase
        .from('chat_rooms')
        .select()
        .or('and(user1.eq.$currentUserId,user2.eq.${user['id']}),and(user1.eq.${user['id']},user2.eq.$currentUserId)')
        .maybeSingle();

    dynamic finalRoom = room;

    // Create if not found
    if (finalRoom == null) {
      finalRoom = await supabase.from('chat_rooms').insert({
        'user1': currentUserId,
        'user2': user['id'],
      }).select().single();
    }

    // Navigate WITH chatRoomId
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatPage(
          otherUserId: user['id'],
          otherUsername: user['username'],
          // 👇 REQUIRED
          chatRoomId: finalRoom['id'],
          isDarkMode: isDarkMode,
        ),
      ),
    );
  }

  Future<void> navigateToSearch() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SearchUsersPage()),
    );

    if (result == true) {
      loadChatUsers();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: isDarkMode ? Colors.grey[900] : Colors.grey[200],
      appBar: AppBar(
        elevation: 0,
        backgroundColor: isDarkMode ? Colors.black : Colors.white,
        title: Text(
          "Chats",
          style: TextStyle(
            color: isDarkMode ? Colors.white : Colors.black,
            fontWeight: FontWeight.bold,
          ),
        ),
        actions: [
          IconButton(
            icon:
            Icon(isDarkMode ? Icons.light_mode : Icons.dark_mode, color: Colors.blue),
            onPressed: () {
              setState(() => isDarkMode = !isDarkMode);
            },
          ),
          IconButton(
            icon: const Icon(Icons.person, color: Colors.blue),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ProfilePage()),
              );
            },
          ),
        ],
      ),

      // BODY
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : chatUsers.isEmpty
          ? _buildEmptyState()
          : _buildChatList(),

      floatingActionButton: FloatingActionButton(
        onPressed: navigateToSearch,
        backgroundColor: Colors.blue,
        child: const Icon(Icons.person_add, color: Colors.white),
      ),
    );
  }

  // Empty state UI (beautiful)
  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.chat_outlined, size: 90, color: Colors.grey[400]),
          const SizedBox(height: 20),
          Text(
            "No chats yet",
            style: TextStyle(fontSize: 22, color: Colors.grey[600]),
          ),
          const SizedBox(height: 10),
          Text(
            "Tap + to find friends",
            style: TextStyle(fontSize: 16, color: Colors.grey[500]),
          ),
        ],
      ),
    );
  }

  // Chat list UI (clean & modern)
  Widget _buildChatList() {
    return ListView.builder(
      itemCount: chatUsers.length,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemBuilder: (context, index) {
        final user = chatUsers[index];

        return AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Material(
            elevation: 2,
            borderRadius: BorderRadius.circular(12),
            color: isDarkMode ? Colors.grey[850] : Colors.white,
            child: ListTile(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              leading: CircleAvatar(
                backgroundColor: Colors.blue,
                child: Text(
                  user['username'][0].toUpperCase(),
                  style: const TextStyle(color: Colors.white, fontSize: 18),
                ),
              ),
              title: Text(
                user['username'],
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: isDarkMode ? Colors.white : Colors.black,
                ),
              ),
              subtitle: Text(
                "Tap to open chat",
                style: TextStyle(
                  color: isDarkMode ? Colors.grey[400] : Colors.grey[700],
                ),
              ),
              onTap: () => openChat(user),
            ),
          ),
        );
      },
    );
  }
}