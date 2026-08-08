import 'dart:typed_data';
import 'dart:io';
import 'dart:async';

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
  Map<String, dynamic>? replyingTo;
  final AudioPlayer audioPlayer = AudioPlayer();
  DateTime? recordingStartTime;
  Duration recordingDuration = Duration.zero;
  Timer? recordingTimer;
  String? loadingVoiceId;
  List<dynamic> messages = [];
  String? chatRoomId;
  bool isLoading = true;
  RealtimeChannel? channel;

  late bool isDarkMode;

  @override
  void initState() {
    super.initState();
    isDarkMode = widget.isDarkMode;
    initializeChat();
    messageController.addListener(_onMessageChanged);
  }

  void _onMessageChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    messageController.removeListener(_onMessageChanged);
    messageController.dispose();
    recordingTimer?.cancel();
    super.dispose();
  }

  Future<void> initializeChat() async {
    try {
      final currentUserId = supabase.auth.currentUser!.id;

      var room = await supabase
          .from('chat_rooms')
          .select()
          .or(
        'and(user1.eq.$currentUserId,user2.eq.${widget
            .otherUserId}),and(user1.eq.${widget
            .otherUserId},user2.eq.$currentUserId)',
      )
          .maybeSingle();

      if (room == null) {
        room = await supabase
            .from('chat_rooms')
            .insert({'user1': currentUserId, 'user2': widget.otherUserId})
            .select()
            .single();
      }

      chatRoomId = room['id'];
      await loadMessages();
      setupRealtimeListener();

      setState(() => isLoading = false);

      WidgetsBinding.instance.addPostFrameCallback((_) => scrollToBottom());
    } catch (e) {
      debugPrint('Error initializing chat: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error initializing chat: $e')));
      }
      setState(() => isLoading = false);
    }
  }

  Future<String> decryptSingleMessage(Map<String, dynamic> message,
      String myPrivateKey,
      String myPublicKey,) async {
    final cryptoService = CryptoService();

    final sender = await supabase
        .from('users')
        .select('public_key')
        .eq('id', message['sender_id'])
        .single();

    final sharedKey = await cryptoService.deriveSharedKey(
      myPrivateKeyHex: myPrivateKey,
      myPublicKeyHex: myPublicKey,
      otherPublicKeyHex: sender['public_key'],
    );

    return await cryptoService.decryptMessage(
      sharedKey: sharedKey,
      encryptedMessage: EncryptedMessage(
        content: message['content'],
        nonce: message['nonce'],
        mac: message['mac'],
      ),
    );
  }

  Future<List<Map<String, dynamic>>> decryptMessages(List data) async {
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
        final Map<String, dynamic> msg = Map<String, dynamic>.from(message);

        // Decrypt the main message
        if (msg['message_type'] == 'text') {
          msg['content'] = await decryptSingleMessage(
            msg,
            myPrivateKey,
            myPublicKey,
          );
        }

        // Decrypt the replied message (if any)
        if (msg['reply_content'] != null &&
            msg['reply_type'] == 'text' &&
            msg['reply_sender_id'] != null) {
          // Get the PUBLIC KEY of the person who originally
          // sent the message we are replying to.
          final replySender = await supabase
              .from('users')
              .select('public_key')
              .eq('id', msg['reply_sender_id'])
              .single();

          final replySenderPublicKey = replySender['public_key'];

          if (replySenderPublicKey == null) {
            throw Exception("Reply sender public key missing");
          }

          // Create shared key with the ORIGINAL sender
          final replySharedKey = await cryptoService.deriveSharedKey(
            myPrivateKeyHex: myPrivateKey,
            myPublicKeyHex: myPublicKey,
            otherPublicKeyHex: replySenderPublicKey,
          );

          final replyEncrypted = EncryptedMessage(
            content: msg['reply_content'],
            nonce: msg['reply_nonce'],
            mac: msg['reply_mac'],
          );

          final replyText = await cryptoService.decryptMessage(
            sharedKey: replySharedKey,
            encryptedMessage: replyEncrypted,
          );

          // Store decrypted reply in memory
          msg['reply_content'] = replyText;
        }

        decryptedMessages.add(msg);
      } catch (e) {
        debugPrint("Decrypt error: $e");

        decryptedMessages.add({...message, 'content': '[Unable to decrypt]'});
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

      for (final message in data) {
        if (message['reply_to'] != null) {
          try {
            final replied = await supabase
                .from('messages')
                .select('id, sender_id, content, message_type, nonce, mac')
                .eq('id', message['reply_to'])
                .single();

            final sender = await supabase
                .from('users')
                .select('username, public_key')
                .eq('id', replied['sender_id'])
                .single();

            message['reply_sender_id'] = replied['sender_id'];
            message['reply_content'] = replied['content'];
            message['reply_type'] = replied['message_type'];
            message['reply_nonce'] = replied['nonce'];
            message['reply_mac'] = replied['mac'];
            message['reply_sender'] = sender['username'];

            debugPrint("========== REPLY ==========");
            debugPrint("reply_to: ${message['reply_to']}");
            debugPrint("reply_sender: ${message['reply_sender']}");
            debugPrint("reply_sender_id: ${message['reply_sender_id']}");
            debugPrint("reply_content: ${message['reply_content']}");
            debugPrint("reply_type: ${message['reply_type']}");
            debugPrint("============================");
          } catch (e) {
            debugPrint("Error loading replied message: $e");
          }
        }
      }

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
    "${directory.path}/voice_${DateTime
        .now()
        .millisecondsSinceEpoch}.m4a";

    await audioRecorder.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
      ),
      path: audioPath!,
    );

    recordingStartTime = DateTime.now();

    recordingTimer?.cancel();

    recordingTimer = Timer.periodic(
      const Duration(seconds: 1),
          (_) {
        if (!mounted || recordingStartTime == null) return;

        setState(() {
          recordingDuration =
              DateTime.now().difference(recordingStartTime!);
        });
      },
    );

    setState(() {
      isRecording = true;
      recordingDuration = Duration.zero;
    });
  }

  Future<void> stopRecording() async {
    final path = await audioRecorder.stop();

    recordingTimer?.cancel();
    recordingTimer = null;

    setState(() {
      isRecording = false;
      recordingDuration = Duration.zero;
      recordingStartTime = null;
    });

    if (path != null) {
      await sendVoiceMessage(path);
    }
  }

  Future<String> uploadVoice(String path) async {
    final file = File(path);

    final filePath =
        "${supabase.auth.currentUser!.id}/${DateTime
        .now()
        .millisecondsSinceEpoch}.m4a";

    await supabase.storage.from('chat-voices').upload(filePath, file);

    final url = supabase.storage.from('chat-voices').getPublicUrl(filePath);

    print("VOICE URL: $url");

    return url;
  }

  Future<void> sendVoiceMessage(String path) async {
    final url = await uploadVoice(path);

    await supabase.from('messages').insert({
      'chat_room_id': chatRoomId,

      'sender_id': supabase.auth.currentUser!.id,

      'content': url,

      'message_type': 'voice',
      'reply_to': replyingTo?['id'],
    });
    setState(() {
      replyingTo = null;
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
          final decrypted = await decryptMessages([payload.newRecord]);

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
        'reply_to': replyingTo?['id'],
      });

      messageController.clear();

      setState(() {
        replyingTo = null;
      });

      await supabase
          .from('chat_rooms')
          .update({'updated_at': DateTime.now().toIso8601String()})
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
          '${user.id}/${chatRoomId}/${DateTime
          .now()
          .millisecondsSinceEpoch}.jpg';

      // Upload image to Supabase Storage
      await supabase.storage.from('chat-media').upload(filePath, imageFile);

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
        "Recipient (${widget
            .otherUserId}) has no public key yet — they need to log in once to generate one.",
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

  String _formatRecordingDuration(Duration duration) {
    final minutes =
    duration.inMinutes.remainder(60).toString().padLeft(2, '0');

    final seconds =
    duration.inSeconds.remainder(60).toString().padLeft(2, '0');

    return '$minutes:$seconds';
  }

  Widget buildMessage(dynamic message) {
    final currentUserId = supabase.auth.currentUser!.id;
    final isMe = message['sender_id'] == currentUserId;

    final timestamp = DateTime.parse(message['created_at']);
    final time =
        '${timestamp.hour.toString().padLeft(2, '0')}:${timestamp.minute
        .toString().padLeft(2, '0')}';

    return GestureDetector(
        onLongPress: () {
          debugPrint("Long pressed message: ${message['id']}");
          setState(() {
            replyingTo = message;
          });
        },
        child: Align(
            alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
              constraints: BoxConstraints(
                maxWidth: MediaQuery
                    .of(context)
                    .size
                    .width * 0.7,
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
              /// Reply Preview
              if (message['reply_to'] != null) ...[
              Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.15),
                borderRadius: BorderRadius.circular(8),
                border: const Border(
                  left: BorderSide(color: Colors.white, width: 3),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    message['reply_sender'] ?? '',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                      fontSize: 12,
                    ),
                  ),

                  const SizedBox(height: 2),

                  Text(
                    message['reply_type'] == 'voice'
                        ? '🎙 Voice message'
                        : message['reply_type'] == 'image'
                        ? '📷 Image'
                        : message['reply_content'] ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
            ],

                    /// Image
                    if (message['message_type'] == 'image')
                      GestureDetector(
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => FullScreenImagePage(
                                imageUrl: message['image_url'],
                              ),
                            ),
                          );
                        },
                        child: ClipRRect(
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
                              return const SizedBox(
                                width: 220,
                                height: 220,
                                child: Center(
                                  child: Icon(
                                    Icons.broken_image,
                                    size: 40,
                                    color: Colors.grey,
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      )

    /// Voice
    else if (message['message_type'] == 'voice')
    Container(
    width: 210,
    padding: const EdgeInsets.symmetric(
    horizontal: 8,
    vertical: 6,
    ),
    child: Row(
    mainAxisSize: MainAxisSize.min,
    children: [
    // Play / Pause button
    Container(
    width: 42,
    height: 42,
    decoration: const BoxDecoration(
    color: Colors.white,
    shape: BoxShape.circle,
    ),
    child: IconButton(
    padding: EdgeInsets.zero,
    icon: Icon(
    playingVoiceId == message['id'] && isPlaying
    ? Icons.pause
        : Icons.play_arrow,
    color: Colors.blue,
    size: 24,
    ),
    onPressed: () async {
    final id = message['id'];

    if (playingVoiceId == id && isPlaying) {
    await audioPlayer.pause();

    setState(() {
    isPlaying = false;
    });
    } else {
    await audioPlayer.setUrl(message['content']);

    await audioPlayer.play();

    setState(() {
    playingVoiceId = id;
    isPlaying = true;
    });
    }
    },
    ),
    ),

    const SizedBox(width: 10),

    // Fake waveform
    Expanded(
    child: Row(
    mainAxisAlignment: MainAxisAlignment.center,
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
    for (final height in [
    8.0,
    14.0,
    20.0,
    11.0,
    25.0,
    16.0,
    30.0,
    18.0,
    12.0,
    23.0,
    15.0,
    27.0,
    10.0,
    19.0,
    13.0,
    ])
    Container(
    width: 3,
    height: height,
    margin: const EdgeInsets.symmetric(
    horizontal: 2,
    ),
    decoration: BoxDecoration(
    color: Colors.white70,
    borderRadius: BorderRadius.circular(3),
    ),
    ),
    ],
    ),
    ),
    ],
    ),
    )
    /// Text
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

    Row(
    mainAxisSize: MainAxisSize.min,
    children: [
    Text(
    time,
    style: TextStyle(
    color: isMe
    ? Colors.white70
        : (isDarkMode ? Colors.grey[400] : Colors.black54),
    fontSize: 11,
    ),
    ),

    if (isMe) ...[
    const SizedBox(width: 4),
    buildMessageStatus(message),
    ],
    ],
    ),
    ],
    ),
    ),
    )
    ,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: isDarkMode
          ? Colors.grey[900]
          : Colors.grey[100], // 👈 theme

      appBar: AppBar(
        elevation: 1,
        backgroundColor: isDarkMode ? Colors.black : Colors.white,
        leading: IconButton(
          icon: Icon(
            Icons.arrow_back,
            color: isDarkMode ? Colors.white : Colors.black,
          ),
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
          // INPUT BAR
          Container(
            decoration: BoxDecoration(
              color: isDarkMode ? Colors.black : Colors.white,
              boxShadow: const [
                BoxShadow(
                  color: Colors.black26,
                  blurRadius: 3,
                  offset: Offset(0, -1),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [

                /// Reply Preview
                if (replyingTo != null)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                    decoration: BoxDecoration(
                      color: Colors.blue.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(12),
                      border: const Border(
                        left: BorderSide(
                          color: Colors.blue,
                          width: 4,
                        ),
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                "Replying to",
                                style: TextStyle(
                                  color: Colors.blue,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),

                              const SizedBox(height: 2),

                              Text(
                                replyingTo!['message_type'] == 'text'
                                    ? replyingTo!['content']
                                    : replyingTo!['message_type'] == 'voice'
                                    ? '🎙 Voice message'
                                    : replyingTo!['message_type'] == 'image'
                                    ? '📷 Image'
                                    : replyingTo!['message_type'].toUpperCase(),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: isDarkMode
                                      ? Colors.white
                                      : Colors.black,
                                ),
                              ),
                            ],
                          ),
                        ),

                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () {
                            setState(() {
                              replyingTo = null;
                            });

                            messageController.clear();
                          },
                        ),
                      ],
                    ),
                  ),

                /// RECORDING UI
                if (isRecording)
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: isDarkMode
                          ? Colors.grey[850]
                          : Colors.grey[200],
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Row(
                      children: [

                        // Red recording indicator
                        Container(
                          width: 12,
                          height: 12,
                          decoration: const BoxDecoration(
                            color: Colors.red,
                            shape: BoxShape.circle,
                          ),
                        ),

                        const SizedBox(width: 10),

                        const Text(
                          "Recording",
                          style: TextStyle(
                            color: Colors.red,
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                          ),
                        ),

                        const SizedBox(width: 10),

                        // Timer
                        Text(
                          _formatRecordingDuration(recordingDuration),
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: isDarkMode
                                ? Colors.white
                                : Colors.black87,
                          ),
                        ),

                        const Spacer(),

                        const Icon(
                          Icons.mic,
                          color: Colors.red,
                        ),
                      ],
                    ),
                  ),

                /// INPUT
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [

                      /// Message field
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(
                            color: isDarkMode
                                ? Colors.grey[800]
                                : Colors.grey[200],
                            borderRadius: BorderRadius.circular(24),
                          ),
                          child: TextField(
                            controller: messageController,
                            enabled: !isRecording,
                            style: TextStyle(
                              color: isDarkMode
                                  ? Colors.white
                                  : Colors.black,
                            ),
                            decoration: InputDecoration(
                              hintText: isRecording
                                  ? "Recording..."
                                  : "Type a message...",
                              hintStyle: TextStyle(
                                color: isDarkMode
                                    ? Colors.grey[400]
                                    : Colors.grey,
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

                      const SizedBox(width: 4),

                      /// Attachment
                      if (!isRecording)
                        IconButton(
                          icon: const Icon(Icons.attach_file),
                          onPressed: pickAndSendImage,
                        ),

                      const SizedBox(width: 4),

                      /// Send / Record button
                      CircleAvatar(
                        backgroundColor: isRecording
                            ? Colors.red
                            : Colors.blue,

                        child: messageController.text.isNotEmpty &&
                            !isRecording
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
          ),
        ],
      ),
    );
  }

  Widget buildMessageStatus(Map<String, dynamic> message) {
    final status = message['status'] ?? 'sent';

    switch (status) {
      case 'sent':
        return const Icon(Icons.done, size: 16, color: Colors.white70);

      case 'delivered':
        return const Icon(Icons.done_all, size: 16, color: Colors.white70);

      case 'read':
        return const Icon(
          Icons.done_all,
          size: 16,
          color: Colors.lightBlueAccent,
        );

      default:
        return const SizedBox();
    }
  }
}
class FullScreenImagePage extends StatelessWidget {
  final String imageUrl;

  const FullScreenImagePage({
    super.key,
    required this.imageUrl,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: Center(
        child: InteractiveViewer(
          minScale: 0.5,
          maxScale: 4.0,
          child: Image.network(
            imageUrl,
            fit: BoxFit.contain,
            loadingBuilder: (context, child, loadingProgress) {
              if (loadingProgress == null) {
                return child;
              }

              return const CircularProgressIndicator(
                color: Colors.white,
              );
            },
            errorBuilder: (context, error, stackTrace) {
              return const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.broken_image,
                    color: Colors.white,
                    size: 60,
                  ),
                  SizedBox(height: 12),
                  Text(
                    "Unable to load image",
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
