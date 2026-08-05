class EncryptedMessage {
  final String content;
  final String nonce;
  final String mac;

  EncryptedMessage({
    required this.content,
    required this.nonce,
    required this.mac,
  });
}