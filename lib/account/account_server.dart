import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_app/account/send_message_helper.dart';
import 'package:flutter_app/blaze/blaze.dart';
import 'package:flutter_app/blaze/blaze_message.dart';
import 'package:flutter_app/blaze/blaze_param.dart';
import 'package:flutter_app/blaze/vo/contact_message.dart';
import 'package:flutter_app/blaze/vo/sticker_message.dart';
import 'package:flutter_app/constants/constants.dart';
import 'package:flutter_app/crypto/encrypted/encrypted_protocol.dart';
import 'package:flutter_app/db/database.dart';
import 'package:flutter_app/db/extension/message_category.dart';
import 'package:flutter_app/db/mixin_database.dart' as db;
import 'package:flutter_app/db/mixin_database.dart';
import 'package:flutter_app/enum/message_category.dart';
import 'package:flutter_app/enum/message_status.dart';
import 'package:flutter_app/utils/attachment_util.dart';
import 'package:flutter_app/utils/load_Balancer_utils.dart';
import 'package:flutter_app/utils/stream_extension.dart';
import 'package:flutter_app/workers/decrypt_message.dart';
import 'package:mixin_bot_sdk_dart/mixin_bot_sdk_dart.dart';
import 'package:uuid/uuid.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart';

class AccountServer {
  static String? sid;

  set language(String language) =>
      client.dio.options.headers['Accept-Language'] = language;

  Future<void> initServer(
    String userId,
    String sessionId,
    String identityNumber,
    String privateKey,
  ) async {
    if (sid == sessionId) return;
    sid = sessionId;

    this.userId = userId;
    this.sessionId = sessionId;
    this.identityNumber = identityNumber;
    this.privateKey = PrivateKey(base64Decode(privateKey));

    client = Client(
      userId: userId,
      sessionId: sessionId,
      privateKey: privateKey,
      scp: scp,
    );
    (client.dio.transformer as DefaultTransformer).jsonDecodeCallback =
        LoadBalancerUtils.jsonDecode;

    await _initDatabase(privateKey);
    start();
  }

  Future _initDatabase(String privateKey) async {
    final databaseConnection = await db.createMoorIsolate(identityNumber);
    database = Database(databaseConnection);
    _attachmentUtil =
        await AttachmentUtil.init(client, database.messagesDao, identityNumber);
    _sendMessageHelper = SendMessageHelper(
        database.messagesDao, database.jobsDao, _attachmentUtil);
    blaze = Blaze(userId, sessionId, privateKey, database, client);

    _decryptMessage = DecryptMessage(
        userId, database, client, sessionId, this.privateKey, _attachmentUtil);
  }

  late String userId;
  late String sessionId;
  late String identityNumber;
  late PrivateKey privateKey;

  late Client client;
  late Database database;
  late Blaze blaze;
  late DecryptMessage _decryptMessage;
  late SendMessageHelper _sendMessageHelper;
  late AttachmentUtil _attachmentUtil;

  final EncryptedProtocol _encryptedProtocol = EncryptedProtocol();

  void start() {
    blaze.connect();
    database.floodMessagesDao
        .findFloodMessage()
        .where((list) => list.isNotEmpty)
        .asyncMapDrop((list) async {
      for (final message in list) {
        await _decryptMessage.process(message);
      }
      return list;
    }).listen((_) {});

    database.jobsDao
        .findAckJobs()
        .where((jobs) => jobs.isNotEmpty == true)
        .asyncMapDrop(_runAckJob)
        .listen((_) {});

    database.jobsDao
        .findRecallMessageJobs()
        .where((jobs) => jobs.isNotEmpty == true)
        .asyncMapDrop(_runRecallJob)
        .listen((_) {});

    database.jobsDao
        .findSendingJobs()
        .where((jobs) => jobs.isNotEmpty == true)
        .asyncMapDrop(_runSendJob)
        .listen((_) {});

    // database.mock();
  }

  Future<void> _runAckJob(List<db.Job> jobs) async {
    final ack = await Future.wait(
      jobs.where((element) => element.blazeMessage != null).map(
        (e) async {
          final map = await LoadBalancerUtils.jsonDecode(e.blazeMessage!);
          return BlazeAckMessage(
              messageId: map['message_id'], status: map['status']);
        },
      ),
    );

    final jobIds = jobs.map((e) => e.jobId).toList();
    await client.messageApi.acknowledgements(ack);
    await database.jobsDao.deleteJobs(jobIds);
  }

  Future<void> _runRecallJob(List<db.Job> jobs) async {
    jobs.where((element) => element.blazeMessage != null).forEach(
      (e) async {
        final blazeParam = BlazeMessageParam(
            conversationId: e.conversationId,
            messageId: const Uuid().v4(),
            category: MessageCategory.messageRecall,
            data: base64.encode(utf8.encode(e.blazeMessage!)));
        final blazeMessage = BlazeMessage(
            id: const Uuid().v4(), action: createMessage, params: blazeParam);
        blaze.deliver(blazeMessage);
        await database.jobsDao.deleteJobById(e.jobId);
      },
    );
  }

  Future<void> _runSendJob(List<db.Job> jobs) async {
    jobs.where((element) => element.blazeMessage != null).forEach((job) async {
      final message =
          await database.messagesDao.sendingMessage(job.blazeMessage!);
      if (message == null) {
        await database.jobsDao.deleteJobById(job.jobId);
      } else {
        if (message.category.isPlain ||
            message.category == MessageCategory.appCard) {
          var content = message.content;
          if (message.category == MessageCategory.appCard ||
              message.category == MessageCategory.plainPost ||
              message.category == MessageCategory.plainText) {
            content = base64.encode(utf8.encode(content!));
          }
          final blazeMessage = _createBlazeMessage(message, content!);
          blaze.deliver(blazeMessage);
          await database.messagesDao
              .updateMessageStatusById(message.messageId, MessageStatus.sent);
          await database.jobsDao.deleteJobById(job.jobId);
        } else if (message.category.isEncrypted) {
          final conversation = await database.conversationDao
              .getConversationById(message.conversationId);
          if (conversation == null) return;
          final participantSessionKey = await database.participantSessionDao
              .getParticipantSessionKeyWithoutSelf(
                  message.conversationId, userId);
          if (participantSessionKey == null) {
            // todo throw checksum
            return;
          }
          final content = _encryptedProtocol.encryptMessage(
              privateKey,
              utf8.encode(message.content!),
              base64.decode(participantSessionKey.publicKey!),
              participantSessionKey.sessionId);
          final blazeMessage =
              _createBlazeMessage(message, base64Encode(content));
          blaze.deliver(blazeMessage);
          await database.messagesDao
              .updateMessageStatusById(message.messageId, MessageStatus.sent);
          await database.jobsDao.deleteJobById(job.jobId);
        } else {
          // todo send signal
        }
      }
    });
  }

  BlazeMessage _createBlazeMessage(db.SendingMessage message, String data) {
    final blazeParam = BlazeMessageParam(
        conversationId: message.conversationId,
        messageId: message.messageId,
        category: message.category,
        data: data,
        quoteMessageId: message.quoteMessageId);

    return BlazeMessage(
        id: const Uuid().v4(), action: createMessage, params: blazeParam);
  }

  Future<void> sendTextMessage(String conversationId, String content,
      {bool isPlain = true, String? quoteMessageId}) async {
    if (content.isEmpty) return;
    await _sendMessageHelper.sendTextMessage(
        conversationId, userId, content, isPlain, quoteMessageId);
  }

  Future<void> sendImageMessage(String conversationId, XFile image,
          {bool isPlain = true, String? quoteMessageId}) =>
      _sendMessageHelper.sendImageMessage(
          conversationId,
          userId,
          image,
          isPlain ? MessageCategory.plainImage : MessageCategory.signalImage,
          quoteMessageId);

  Future<void> sendVideoMessage(String conversationId, XFile video,
          {bool isPlain = true, String? quoteMessageId}) =>
      _sendMessageHelper.sendVideoMessage(
          conversationId,
          userId,
          video,
          isPlain ? MessageCategory.plainVideo : MessageCategory.signalVideo,
          quoteMessageId);

  Future<void> sendAudioMessage(String conversationId, XFile audio,
          {bool isPlain = true, String? quoteMessageId}) =>
      _sendMessageHelper.sendAudioMessage(
          conversationId,
          userId,
          audio,
          isPlain ? MessageCategory.plainAudio : MessageCategory.signalAudio,
          quoteMessageId);

  Future<void> sendDataMessage(String conversationId, XFile file,
          {bool isPlain = true, String? quoteMessageId}) =>
      _sendMessageHelper.sendDataMessage(
          conversationId,
          userId,
          file,
          isPlain ? MessageCategory.plainData : MessageCategory.signalData,
          quoteMessageId);

  Future<void> sendStickerMessage(String conversationId, String stickerId,
          {bool isPlain = true}) =>
      _sendMessageHelper.sendStickerMessage(
          conversationId,
          userId,
          StickerMessage(stickerId, null, null),
          isPlain
              ? MessageCategory.plainSticker
              : MessageCategory.signalSticker);

  void sendContactMessage(
      String conversationId, String shareUserId, String shareUserFullName,
      {bool isPlain = true, String? quoteMessageId}) {
    _sendMessageHelper.sendContactMessage(
        conversationId,
        userId,
        ContactMessage(shareUserId),
        shareUserFullName,
        isPlain,
        quoteMessageId);
  }

  Future<void> sendRecallMessage(
          String conversationId, List<String> messageIds) =>
      _sendMessageHelper.sendRecallMessage(conversationId, messageIds);

  Future<void> forwardMessage(
          String conversationId, String forwardMessageId, bool isPlain) =>
      _sendMessageHelper.forwardMessage(
          conversationId, userId, forwardMessageId, isPlain);

  void selectConversation(String? conversationId) {
    _decryptMessage.setConversationId(conversationId);
    _markRead(conversationId);
  }

  void _markRead(conversationId) async {
    final ids =
        await database.messagesDao.getUnreadMessageIds(conversationId, userId);
    final status = EnumToString.convertToString(MessageStatus.read);
    final now = DateTime.now();
    final jobs = ids
        .map(
            (id) => jsonEncode(BlazeAckMessage(messageId: id, status: status!)))
        .map((blazeMessage) => Job(
            jobId: const Uuid().v4(),
            action: acknowledgeMessageReceipts,
            priority: 5,
            blazeMessage: blazeMessage,
            createdAt: now,
            runCount: 0))
        .toList();
    database.jobsDao.insertAll(jobs);
  }

  Future<void> stop() async {
    await Future.wait([
      blaze.disconnect(),
      database.dispose(),
    ]);
  }

  void release() {
    // todo release resource
  }

  void initSticker() {
    client.accountApi.getStickerAlbums().then((res) {
      if (res.data != null) {
        res.data!.forEach((item) async {
          await database.stickerAlbumsDao.insert(db.StickerAlbum(
              albumId: item.albumId,
              name: item.name,
              iconUrl: item.iconUrl,
              createdAt: item.createdAt,
              updateAt: item.updateAt,
              userId: item.userId,
              category: item.category,
              description: item.description));
          _updateStickerAlbums(item.albumId);
        });
      }
    }).catchError((e) {
      debugPrint(e);
    });
  }

  final refreshUserIdSet = <dynamic>{};

  void initCircles() {
    refreshUserIdSet.clear();
    client.circleApi.getCircles().then((res) {
      if (res.data != null) {
        res.data?.forEach((circle) async {
          await database.circlesDao.insertUpdate(Circle(
              circleId: circle.circleId,
              name: circle.name,
              createdAt: circle.createdAt,
              orderedAt: null));
          await handleCircle(circle);
        });
      }
    }).catchError((e) {
      debugPrint(e);
    });
  }

  Future<void> handleCircle(CircleResponse circle, {int? offset}) async {
    final ccList =
        (await client.circleApi.getCircleConversations(circle.circleId)).data;
    if (ccList == null) {
      return;
    }
    ccList.forEach((cc) async {
      await database.circleConversationDao.insert(db.CircleConversation(
          conversationId: cc.conversationId,
          circleId: cc.circleId,
          createdAt: cc.createdAt));
      if (cc.userId != null && !refreshUserIdSet.contains(cc.userId)) {
        final u = await database.userDao.findUserById(cc.userId);
        if (u == null) {
          refreshUserIdSet.add(cc.userId);
        }
      }
    });
    if (ccList.length >= 500) {
      await handleCircle(circle, offset: offset ?? 0 + 500);
    }
  }

  void _updateStickerAlbums(String albumId) {
    client.accountApi.getStickersByAlbumId(albumId).then((res) {
      if (res.data != null) {
        final relationships = <StickerRelationship>[];
        res.data!.forEach((sticker) {
          relationships.add(StickerRelationship(
              albumId: albumId, stickerId: sticker.stickerId));
          database.stickerDao.insert(db.Sticker(
            stickerId: sticker.stickerId,
            albumId: albumId,
            name: sticker.name,
            assetUrl: sticker.assetUrl,
            assetType: sticker.assetType,
            assetWidth: sticker.assetWidth,
            assetHeight: sticker.assetHeight,
            createdAt: sticker.createdAt,
          ));
        });

        database.stickerRelationshipsDao.insertAll(relationships);
      }
    }).catchError((e) {
      debugPrint(e);
    });
  }

  Future<String?> downloadAttachment(db.MessageItem message) =>
      _attachmentUtil.downloadAttachment(
        content: message.content!,
        messageId: message.messageId,
        conversationId: message.conversationId,
        category: message.type,
      );

  Future<void> reUploadAttachment(db.MessageItem message) =>
      _sendMessageHelper.reUploadAttachment(
          message.conversationId,
          message.messageId,
          File(message.mediaUrl!),
          message.mediaName,
          message.mediaMimeType!,
          message.mediaSize!,
          message.mediaWidth,
          message.mediaHeight,
          message.thumbImage,
          message.mediaDuration,
          message.mediaWaveform);

  Future<void> addUser(String userId) => _relationship(
      RelationshipRequest(userId: userId, action: RelationshipAction.add));

  Future<void> removeUser(String userId) => _relationship(
      RelationshipRequest(userId: userId, action: RelationshipAction.remove));

  Future<void> blockUser(String userId) => _relationship(
      RelationshipRequest(userId: userId, action: RelationshipAction.block));

  Future<void> unblockUser(String userId) => _relationship(
      RelationshipRequest(userId: userId, action: RelationshipAction.unblock));

  Future<void> _relationship(RelationshipRequest request) async {
    await client.userApi.relationships(request).then((response) async {
      final user = response.data;
      if (user != null) {
        await database.userDao.insert(db.User(
            userId: user.userId,
            identityNumber: user.identityNumber,
            relationship: user.relationship,
            fullName: user.fullName,
            avatarUrl: user.avatarUrl,
            phone: user.phone,
            isVerified: user.isVerified ? 1 : 0,
            appId: user.app?.appId,
            biography: user.biography,
            muteUntil: DateTime.tryParse(user.muteUntil),
            isScam: user.isScam ? 1 : 0,
            createdAt: user.createdAt));
      }
    }).catchError((e) {
      debugPrint(e);
    });
  }

  Future<void> createGroupConversation(String name, List<db.User> users) async {
    final conversationId = const Uuid().v4();
    final response = await client.conversationApi.createConversation(
        ConversationRequest(conversationId: conversationId, name: name.trim()));
    if (response.data != null) {
      final conversation = response.data!;
      await database.conversationDao.insert(db.Conversation(
          conversationId: conversation.conversationId,
          ownerId: conversation.creatorId,
          category: conversation.category,
          name: conversation.name,
          iconUrl: conversation.iconUrl,
          announcement: conversation.announcement,
          codeUrl: conversation.codeUrl,
          payType: null,
          createdAt: conversation.createdAt,
          pinTime: null,
          lastMessageId: null,
          lastMessageCreatedAt: null,
          lastReadMessageId: null,
          unseenMessageCount: 0,
          status: ConversationStatus.success,
          draft: null,
          muteUntil: DateTime.tryParse(conversation.muteUntil)));
      conversation.participants.forEach((participant) async {
        database.participantsDao.insert(db.Participant(
            conversationId: conversation.conversationId,
            userId: participant.userId,
            createdAt: participant.createdAt ?? DateTime.now(),
            role: participant.role));
      });
    }
  }

  Future<void> exitGroup(String conversationId) async {
    await client.conversationApi
        .exit(conversationId)
        .then((response) => {})
        .catchError((error) {
      debugPrint(error);
    });
  }

  Future<void> addParticipant(
    String conversationId,
    String userId,
  ) async {
    await client.conversationApi
        .participants(conversationId, 'ADD',
            [ParticipantRequest(userId: userId)])
        .then((response) => {})
        .catchError((error) {
          debugPrint(error);
        });
  }

  Future<void> removeParticipant(
      String conversationId,
      String userId,
      ) async {
    await client.conversationApi
        .participants(conversationId, 'REMOVE',
        [ParticipantRequest(userId: userId)])
        .then((response) => {})
        .catchError((error) {
      debugPrint(error);
    });
  }

  Future<void> updateParticipantRole(
      String conversationId,
      String userId,
      ParticipantRole role
      ) async {
    await client.conversationApi
        .participants(conversationId, 'REMOVE',
        [ParticipantRequest(userId: userId, role: role)])
        .then((response) => {})
        .catchError((error) {
      debugPrint(error);
    });
  }

}
