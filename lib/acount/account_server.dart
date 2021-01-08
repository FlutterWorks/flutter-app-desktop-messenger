import 'package:flutter_app/blaze/blaze.dart';
import 'package:flutter_app/constans.dart';
import 'package:flutter_app/db/database.dart';
import 'package:mixin_bot_sdk_dart/mixin_bot_sdk_dart.dart';

class AccountServer {
  void initServer(
    String userId,
    String sessionId,
    String identityNumber,
    String privateKey,
  ) {
    assert(userId != null);
    assert(sessionId != null);
    assert(identityNumber != null);
    assert(privateKey != null);

    this.userId = userId;
    this.sessionId = sessionId;
    this.identityNumber = identityNumber;
    this.privateKey = privateKey;
    database = Database(identityNumber);
    client.initMixin(userId, sessionId, privateKey, scp);
    blaze = Blaze(userId, sessionId, privateKey, database, client);
  }

  String userId;
  String sessionId;
  String identityNumber;
  String privateKey;

  final Client client = Client();
  Database database;
  Blaze blaze;
  WorkManager workManager;

  void relase() {
    // Todo relase resource
  }
}

class WorkManager {}
