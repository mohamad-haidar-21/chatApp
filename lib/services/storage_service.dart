import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

class StorageService {
  final supabase = Supabase.instance.client;

  Future<String> uploadEncryptedFile({
    required Uint8List bytes,
    required String chatRoomId,
    required String fileName,
  }) async {
    final path =
        "$chatRoomId/${DateTime.now().millisecondsSinceEpoch}_$fileName.enc";

    await supabase.storage
        .from("chat-media")
        .uploadBinary(
      path,
      bytes,
      fileOptions: const FileOptions(
        upsert: false,
      ),
    );

    return path;
  }

  Future<Uint8List> downloadEncryptedFile(
      String path,
      ) async {
    return await supabase.storage
        .from("chat-media")
        .download(path);
  }
}