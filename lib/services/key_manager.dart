import 'package:flutter/cupertino.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'crypto_service.dart';
import 'key_storage.dart';

class KeyManager {
  final supabase = Supabase.instance.client;

  final CryptoService crypto = CryptoService();
  final KeyStorage storage = KeyStorage();

  Future<void> initializeEncryptionKeys() async {
    final cryptoService = CryptoService();
    final storage = KeyStorage();

    final currentUser = supabase.auth.currentUser;

    if (currentUser == null) {
      return;
    }


    // Check if keys already exist
    final existingPrivateKey = await storage.getPrivateKey();
    final existingPublicKey = await storage.getPublicKey();


    if (existingPrivateKey != null && existingPublicKey != null) {
      debugPrint("Keys already exist");
      return;
    }


    // Generate new keys
    final keyPair = await cryptoService.generateKeyPair();


    final publicKey =
    await cryptoService.getPublicKey(keyPair);

    final privateKey =
    await cryptoService.getPrivateKey(keyPair);


    // Save locally
    await storage.savePrivateKey(privateKey);
    await storage.savePublicKey(publicKey);


    // Upload public key
    await supabase
        .from('users')
        .update({
      'public_key': publicKey,
    })
        .eq('id', currentUser.id);


    debugPrint("Encryption keys created");
  }
}