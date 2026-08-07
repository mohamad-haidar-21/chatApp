import 'dart:typed_data';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:just_audio/just_audio.dart';

import '../models/encrypted_message.dart';
import '../services/crypto_service.dart';
import '../services/image_service.dart';
import '../services/key_storage.dart';
import '../services/storage_service.dart';

class ChatPage extends StatefulWidget {
  final String otherUserId;
  final String otherUsername;
  final String chatRoomId;
  final bool isDarkMode; // 👈 add this

  const ChatPage({
    super.key,
    required this.otherUserId,
    required this.otherUsername,
    required this.chatRoomId,
    required this.isDarkMode, // 👈 receive from HomePage
  });

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final supabase = Supabase.instance.client;
  final messageController = TextEditingController();
  final scrollController = ScrollController();

  final AudioRecorder audioRecorder = AudioRecorder();

  String? audioPath;

  bool isRecording = false;
  String? playingVoiceId;
  bool isPlaying = false;
  final AudioPlayer audioPlayer = AudioPlayer();

  List<dynamic> messages = [];
  String? chatRoomId;
  bool isLoading = true;
  RealtimeChannel? channel;

  late bool isDarkMode;

  @override
  void initState() {
    super.initState();
    isDarkMode = widget.isDarkMode; // 👈 inherit theme
    initializeChat();
  }

  @override
  void dispose() {
    messageController.dispose();
    scrollController.dispose();
    channel?.unsubscribe();
    super.dispose();
  }

  Future<void> initializeChat() async {
    try {
      final currentUserId = supabase.auth.currentUser!.id;

      var room = await supabase
          .from('chat_rooms')
          .select()
          .or('and(user1.eq.$currentUserId,user2.eq.${widget.otherUserId}),and(user1.eq.${widget.otherUserId},user2.eq.$currentUserId)')
          .maybeSingle();

      if (room == null) {
        room = await supabase.from('chat_rooms').insert({
          'user1': currentUserId,
          'user2': widget.otherUserId,
        }).select().single();
      }

      chatRoomId = room['id'];
      await loadMessages();
      setupRealtimeListener();

      setState(() => isLoading = false);

      WidgetsBinding.instance.addPostFrameCallback((_) => scrollToBottom());
    } catch (e) {
      debugPrint('Error initializing chat: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error initializing chat: $e')),
        );
      }
      setState(() => isLoading = false);
    }
  }
  Future<List<Map<String, dynamic>>> decryptMessages(
      List<dynamic> data) async {

    final cryptoService = CryptoService();
    final storage = KeyStorage();

    final myPrivateKey = await storage.getPrivateKey();
    final myPublicKey = await storage.getPublicKey();

    if (myPrivateKey == null || myPublicKey == null) {
      throw Exception("Encryption keys not found");
    }

    List<Map<String, dynamic>> decryptedMessages = [];


    for (final message in data) {

      try {

        // Detect message type first
        final messageType = message['message_type'] ?? 'text';


        debugPrint("MESSAGE TYPE: $messageType");
        debugPrint("IMAGE URL: ${message['image_url']}");
        if (messageType == 'image' || messageType == 'voice') {

          decryptedMessages.add({
            ...message,
            'content': message['content'],
          });

          continue;
        }



        // Get sender public key
        final sender = await supabase
            .from('users')
            .select('public_key')
            .eq('id', message['sender_id'])
            .single();


        final senderPublicKey = sender['public_key'];


        if (senderPublicKey == null) {
          throw Exception("Sender public key missing");
        }



        // Create shared key
        final sharedKey = await cryptoService.deriveSharedKey(
          myPrivateKeyHex: myPrivateKey,
          myPublicKeyHex: myPublicKey,
          otherPublicKeyHex: senderPublicKey,
        );

        final encryptedMessage = EncryptedMessage(
          content: message['content'],
          nonce: message['nonce'],
          mac: message['mac'],
        );



        final decryptedText = await cryptoService.decryptMessage(
          sharedKey: sharedKey,
          encryptedMessage: encryptedMessage,
        );



        decryptedMessages.add({
          ...message,
          'content': decryptedText,
        });



      } catch (e) {

        debugPrint(
          "Message decrypt error: $e",
        );


        // Keep image messages even if something fails
        if (message['message_type'] == 'image' ) {

          decryptedMessages.add({
            ...message,
            'content': '',
          });

        } else {

          decryptedMessages.add({
            ...message,
            'content': '[Unable to decrypt]',
          });

        }
      }
    }


    return decryptedMessages;
  }


  Future<void> loadMessages() async {
    if (chatRoomId == null) return;

    try {

      final data = await supabase
          .from('messages')
          .select()
          .eq('chat_room_id', chatRoomId!)
          .order('created_at', ascending: true);


      final decrypted = await decryptMessages(data);


      setState(() {
        messages = decrypted;
      });


    } catch (e) {
      debugPrint('Error loading messages: $e');
    }
  }
  Future<void> startRecording() async {

    if (!await audioRecorder.hasPermission()) {
      return;
    }


    final directory = await getTemporaryDirectory();


    audioPath =
    "${directory.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a";


    await audioRecorder.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
      ),
      path: audioPath!,
    );


    setState(() {
      isRecording = true;
    });

  }
  Future<void> stopRecording() async {

    final path = await audioRecorder.stop();


    setState(() {
      isRecording = false;
    });


    if(path != null){

      await sendVoiceMessage(path);

    }

  }
  Future<String> uploadVoice(String path) async {

    final file = File(path);

    final filePath =
        "${supabase.auth.currentUser!.id}/${DateTime.now().millisecondsSinceEpoch}.m4a";


    await supabase.storage
        .from('chat-voices')
        .upload(
      filePath,
      file,
    );


    final url = supabase.storage
        .from('chat-voices')
        .getPublicUrl(filePath);


    print("VOICE URL: $url");


    return url;
  }
  Future<void> sendVoiceMessage(String path) async {


    final url = await uploadVoice(path);


    await supabase
        .from('messages')
        .insert({

      'chat_room_id': chatRoomId,

      'sender_id':
      supabase.auth.currentUser!.id,

      'content': url,

      'message_type': 'voice',

    });


  }


  void setupRealtimeListener() {
    if (chatRoomId == null) return;

    channel = supabase
        .channel("messages:$chatRoomId")
        .onPostgresChanges(
      event: PostgresChangeEvent.insert,
      schema: 'public',
      table: 'messages',
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'chat_room_id',
        value: chatRoomId,
      ),
      callback: (payload) async {
        if (!mounted) return;

        try {
          final decrypted =
          await decryptMessages([payload.newRecord]);

          if (!mounted) return;

          setState(() {
            messages.add(decrypted.first);
          });

          scrollToBottom();
        } catch (e) {
          debugPrint("Realtime decrypt error: $e");
        }
      },
    )
        .subscribe();
  }

  Future<void> sendMessage() async {
    final content = messageController.text.trim();

    if (content.isEmpty || chatRoomId == null) return;

    final cryptoService = CryptoService();

    try {
      final currentUserId = supabase.auth.currentUser!.id;

      final sharedKey = await getSharedKey();

      final encrypted = await cryptoService.encryptMessage(
        sharedKey: sharedKey,
        message: content,
      );

      await supabase.from('messages').insert({
        'chat_room_id': chatRoomId,
        'sender_id': currentUserId,
        'message_type': 'text',
        'content': encrypted.content,
        'nonce': encrypted.nonce,
        'mac': encrypted.mac,
        'media_path': null,
      });

      messageController.clear();

      await supabase
          .from('chat_rooms')
          .update({
        'updated_at': DateTime.now().toIso8601String(),
      })
          .eq('id', chatRoomId!);

      scrollToBottom();
    } catch (e) {
      debugPrint("Send Message Error: $e");
    }
  }
  void scrollToBottom() {
    if (scrollController.hasClients) {
      Future.delayed(const Duration(milliseconds: 120), () {
        if (scrollController.hasClients) {
          scrollController.animateTo(
            scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }
  Future<void> sendImage(File imageFile) async {
    try {
      final user = supabase.auth.currentUser;

      if (user == null) {
        throw Exception("User not logged in");
      }

      // Create a unique file path
      final filePath =
          '${user.id}/${chatRoomId}/${DateTime.now().millisecondsSinceEpoch}.jpg';


      // Upload image to Supabase Storage
      await supabase.storage
          .from('chat-media')
          .upload(
        filePath,
        imageFile,
      );


      // Get public URL
      final imageUrl = supabase.storage
          .from('chat-media')
          .getPublicUrl(filePath);


      // Insert message into messages table
      await supabase.from('messages').insert({
        'chat_room_id': chatRoomId,
        'sender_id': user.id,
        'image_url': imageUrl,
        'content': '',
        'message_type': 'image',
      });


      print("Image sent successfully");

    } catch (e) {
      print("Send Image Error: $e");
    }
  }
  Future<SecretKey> getSharedKey() async {
    final cryptoService = CryptoService();
    final storage = KeyStorage();

    final myPrivateKey = await storage.getPrivateKey();
    final myPublicKey = await storage.getPublicKey();

    if (myPrivateKey == null || myPublicKey == null) {
      throw Exception("Encryption keys not found.");
    }

    final receiver = await supabase
        .from('users')
        .select('public_key')
        .eq('id', widget.otherUserId)
        .single();

    final receiverPublicKey = receiver['public_key'] as String?;

    if (receiverPublicKey == null || receiverPublicKey.isEmpty) {
      throw Exception(
        "Recipient (${widget.otherUserId}) has no public key yet — they need to log in once to generate one.",
      );
    }

    return cryptoService.deriveSharedKey(
      myPrivateKeyHex: myPrivateKey,
      myPublicKeyHex: myPublicKey,
      otherPublicKeyHex: receiverPublicKey,
    );
  }
  Future<void> pickAndSendImage() async {
    final imageService = ImageService();
    final image = await imageService.pickImageFromGallery();

    if (image != null) {
      await sendImage(image);
    }
  }


  Widget buildMessage(dynamic message) {
    final currentUserId = supabase.auth.currentUser!.id;
    final isMe = message['sender_id'] == currentUserId;
    final timestamp = DateTime.parse(message['created_at']);
    final time =
        '${timestamp.hour.toString().padLeft(2, '0')}:${timestamp.minute.toString().padLeft(2, '0')}';

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.7,
        ),
        decoration: BoxDecoration(
          color: isMe
              ? Colors.blue
              : (isDarkMode ? Colors.grey[800] : Colors.grey[300]),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isMe ? 16 : 4),
            bottomRight: Radius.circular(isMe ? 4 : 16),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [

            if (message['message_type'] == 'image')
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.network(
                  message['image_url'],
                  width: 220,
                  height: 220,
                  fit: BoxFit.cover,

                  loadingBuilder: (context, child, loadingProgress) {
                    if (loadingProgress == null) {
                      return child;
                    }

                    return SizedBox(
                      width: 220,
                      height: 220,
                      child: Center(
                        child: CircularProgressIndicator(
                          value: loadingProgress.expectedTotalBytes != null
                              ? loadingProgress.cumulativeBytesLoaded /
                              loadingProgress.expectedTotalBytes!
                              : null,
                        ),
                      ),
                    );
                  },

                  errorBuilder: (context, error, stackTrace) {
                    debugPrint("IMAGE LOAD ERROR: $error");
                    debugPrint("IMAGE URL: ${message['image_url']}");

                    return const Center(
                      child: Icon(Icons.error),
                    );
                  },
                ),
              )

            else if (message['message_type'] == 'voice')
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [

                  IconButton(
                    icon: Icon(
                      playingVoiceId == message['id'] && isPlaying
                          ? Icons.pause
                          : Icons.play_arrow,
                      color: Colors.white,
                    ),
                    onPressed: () async {

                      final id = message['id'];

                      if (playingVoiceId == id && isPlaying) {

                        await audioPlayer.pause();

                        setState(() {
                          isPlaying = false;
                        });

                      } else {

                        await audioPlayer.setUrl(
                          message['content'],
                        );

                        await audioPlayer.play();

                        setState(() {
                          playingVoiceId = id;
                          isPlaying = true;
                        });

                      }
                    },
                  ),
                  const Text(
                    "Voice message",
                    style: TextStyle(
                      fontSize: 15,
                    ),
                  ),

                ],
              )


            else
              Text(
                message['content'],
                style: TextStyle(
                  color: isMe
                      ? Colors.white
                      : (isDarkMode ? Colors.white : Colors.black),
                  fontSize: 16,
                ),
              ),


            const SizedBox(height: 4),


            Text(
              time,
              style: TextStyle(
                color: isMe
                    ? Colors.white70
                    : (isDarkMode ? Colors.grey[400] : Colors.black54),
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor:
      isDarkMode ? Colors.grey[900] : Colors.grey[100], // 👈 theme

      appBar: AppBar(
        elevation: 1,
        backgroundColor: isDarkMode ? Colors.black : Colors.white,
        leading: IconButton(
          icon: Icon(Icons.arrow_back,
              color: isDarkMode ? Colors.white : Colors.black),
          onPressed: () => Navigator.pop(context),
        ),
        title: Row(
          children: [
            CircleAvatar(
              backgroundColor: Colors.blue,
              radius: 18,
              child: Text(
                widget.otherUsername[0].toUpperCase(),
                style: const TextStyle(color: Colors.white, fontSize: 16),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                widget.otherUsername,
                style: TextStyle(
                  color: isDarkMode ? Colors.white : Colors.black,
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),

      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
        children: [
          Expanded(
            child: messages.isEmpty
                ? Center(
              child: Text(
                "No messages yet",
                style: TextStyle(
                  fontSize: 18,
                  color: isDarkMode
                      ? Colors.grey[400]
                      : Colors.grey[600],
                ),
              ),
            )
                : ListView.builder(
              controller: scrollController,
              padding: const EdgeInsets.symmetric(vertical: 10),
              itemCount: messages.length,
              itemBuilder: (context, index) {
                return buildMessage(messages[index]);
              },
            ),
          ),

          // INPUT BAR
          Container(
            padding:
            const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            decoration: BoxDecoration(
              color: isDarkMode ? Colors.black : Colors.white,
              boxShadow: [
                BoxShadow(
                  color: Colors.black26,
                  blurRadius: 3,
                  offset: const Offset(0, -1),
                )
              ],
            ),
            child: Row(
              children: [
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: isDarkMode ? Colors.grey[800] : Colors.grey[200],
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: TextField(
                      controller: messageController,
                      style: TextStyle(
                        color: isDarkMode ? Colors.white : Colors.black,
                      ),
                      decoration: InputDecoration(
                        hintText: "Type a message...",
                        hintStyle: TextStyle(
                          color: isDarkMode ? Colors.grey[400] : Colors.grey,
                        ),
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 10,
                        ),
                      ),
                    ),
                  ),
                ),

                IconButton(
                  icon: const Icon(Icons.attach_file),
                  onPressed: pickAndSendImage,
                ),

                const SizedBox(width: 4),

                CircleAvatar(
                  backgroundColor: Colors.blue,
                  child: messageController.text.isNotEmpty
                      ? IconButton(
                    icon: const Icon(
                      Icons.send,
                      color: Colors.white,
                    ),
                    onPressed: sendMessage,
                  )
                      : GestureDetector(
                    onLongPressStart: (_) async {
                      await startRecording();
                    },
                    onLongPressEnd: (_) async {
                      await stopRecording();
                    },
                    child: Icon(
                      isRecording
                          ? Icons.mic
                          : Icons.mic_none,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
