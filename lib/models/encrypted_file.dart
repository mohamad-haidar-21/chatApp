import 'dart:typed_data';

class EncryptedFile {
  final Uint8List encryptedBytes;
  final String nonce;
  final String mac;

  EncryptedFile({
    required this.encryptedBytes,
    required this.nonce,
    required this.mac,
  });
}