import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:mixin_bot_sdk_dart/mixin_bot_sdk_dart.dart';

import '../../db/database.dart';
import '../../db/mixin_database.dart';
import '../attachment/attachment_util.dart';
import '../extension/extension.dart';
import '../logger.dart';
import 'json_transfer_data.dart';
import 'transfer_data_app.dart';
import 'transfer_data_asset.dart';
import 'transfer_data_command.dart';
import 'transfer_data_conversation.dart';
import 'transfer_data_expired_message.dart';
import 'transfer_data_message.dart';
import 'transfer_data_participant.dart';
import 'transfer_data_pin_message.dart';
import 'transfer_data_snapshot.dart';
import 'transfer_data_sticker.dart';
import 'transfer_data_transcript_message.dart';
import 'transfer_data_user.dart';
import 'transfer_protocol.dart';

typedef OnReceiverStart = void Function();
typedef OnReceiverSucceed = void Function();
typedef OnReceiverFailed = void Function();

/// [progress] is between 0.0 and 100.0
typedef OnReceiverProgressUpdate = void Function(double progress);

class DeviceTransferReceiver {
  DeviceTransferReceiver({
    required this.database,
    required this.attachmentUtil,
    required this.userId,
    required this.protocolTransform,
    required this.deviceId,
    this.onReceiverStart,
    this.onReceiverSucceed,
    this.onReceiverFailed,
    this.onReceiverProgressUpdate,
  });

  final Database database;
  final AttachmentUtilBase attachmentUtil;
  final String userId;
  final TransferProtocolTransform protocolTransform;
  final String deviceId;

  final OnReceiverStart? onReceiverStart;
  final OnReceiverSucceed? onReceiverSucceed;
  final OnReceiverFailed? onReceiverFailed;
  final OnReceiverProgressUpdate? onReceiverProgressUpdate;

  Socket? _socket;
  int _total = 0;
  int _progress = 0;
  var _lastProgressNotifyTime = DateTime(0);

  var _finished = false;

  void _resetTransferStates() {
    _total = 0;
    _progress = 0;
    _finished = false;
    _lastProgressNotifyTime = DateTime(0);
  }

  Future<void> _notifyProgressUpdate() async {
    _progress++;
    final progress =
        _total == 0 ? 0.0 : (_progress / _total * 100.0).clamp(0.0, 100.0);
    onReceiverProgressUpdate?.call(progress);
    if (DateTime.now().difference(_lastProgressNotifyTime) >
        const Duration(milliseconds: 200)) {
      _lastProgressNotifyTime = DateTime.now();
      await _socket?.addCommand(
        TransferDataCommand.progress(deviceId: deviceId, progress: progress),
      );
      d('progress: $progress');
    }
  }

  Future<void> _notifyProgressComplete() async {
    onReceiverProgressUpdate?.call(100);
    await _socket?.addCommand(
      TransferDataCommand.progress(deviceId: deviceId, progress: 100),
    );
  }

  Future<void> connectToServer(String ip, int port, int code) async {
    d('connect to $ip:$port');
    if (_socket != null) {
      w('socket is not null, close it first');
      close();
    }
    _finished = false;
    final socket = await Socket.connect(
      ip,
      port,
      timeout: const Duration(seconds: 10),
    );
    _resetTransferStates();
    _socket = socket;
    d('connected to $ip:$port. my port: ${socket.port}');
    socket.transform(protocolTransform).asyncListen(
      (packet) async {
        try {
          if (packet is TransferJsonPacket) {
            if (packet.json.type != JsonTransferDataType.command) {
              // notify progress, command is not counted.
              await _notifyProgressUpdate();
            }
            await _processReceivedJsonPacket(packet.json);
          } else if (packet is TransferAttachmentPacket) {
            await _processReceivedAttachmentPacket(packet);
            await _notifyProgressUpdate();
          } else {
            e('unknown packet: $packet');
          }
        } catch (error, stacktrace) {
          if (_socket == null) {
            e('socket is null, ignore error $error');
            return;
          }
          e('process packet error: $error $stacktrace');
          close();
        }
      },
      onDone: () {
        d('receiver: socket done. finished: $_finished');
        if (_finished) {
          onReceiverSucceed?.call();
        } else {
          onReceiverFailed?.call();
        }
        close();
      },
      onError: (error, stacktrace) {
        e('_handleRemotePushCommand: $error $stacktrace');
        onReceiverFailed?.call();
        close();
      },
    );
    await socket.addCommand(
      TransferDataCommand.connect(
        code: code,
        deviceId: deviceId,
        userId: userId,
      ),
    );
  }

  Future<void> _processReceivedJsonPacket(JsonTransferData data) async {
    try {
      switch (data.type) {
        case JsonTransferDataType.conversation:
          final conversation = TransferDataConversation.fromJson(data.data);
          d('client: conversation: $conversation');
          final local = await database.conversationDao
              .conversationById(conversation.conversationId)
              .getSingleOrNull();
          if (local != null) {
            i('conversation already exist: ${conversation.conversationId}');
            return;
          }
          await database.conversationDao
              .insert(conversation.toDbConversation());
          break;
        case JsonTransferDataType.message:
          final message = TransferDataMessage.fromJson(data.data);
          d('client: message: $message');
          final local = await database.messageDao
              .findMessageByMessageId(message.messageId);
          if (local != null) {
            d('message already exist: ${message.messageId}');
            return;
          }
          final dbMessage =
              message.toDbMessage().copyWith(status: MessageStatus.read);
          await database.messageDao.insert(dbMessage, userId);
          await database.ftsDatabase.insertFts(dbMessage);
          break;
        case JsonTransferDataType.asset:
          final asset = TransferDataAsset.fromJson(data.data);
          d('client: asset: $asset');
          await database.assetDao.insertAsset(asset.toDbAsset());
          break;
        case JsonTransferDataType.user:
          final user = TransferDataUser.fromJson(data.data);
          d('client: user: $user');
          await database.userDao
              .insert(user.toDbUser(), updateIfConflict: false);
          break;
        case JsonTransferDataType.sticker:
          final sticker = TransferDataSticker.fromJson(data.data);
          d('client: sticker: $sticker');
          await database.stickerDao.insertSticker(sticker.toDbSticker());
          break;
        case JsonTransferDataType.snapshot:
          final snapshot = TransferDataSnapshot.fromJson(data.data);
          d('client: snapshot: $snapshot');
          await database.snapshotDao
              .insert(snapshot.toDbSnapshot(), updateIfConflict: false);
          break;
        case JsonTransferDataType.command:
          final command = TransferDataCommand.fromJson(data.data);
          d('client: command: $command');
          switch (command.action) {
            case kTransferCommandActionFinish:
              i('${command.action} command: finish receiver socket');
              _finished = true;
              await _notifyProgressComplete();
              assert(_socket != null, 'socket is null');
              await _socket?.addCommand(TransferDataCommand.simple(
                  deviceId: deviceId, action: kTransferCommandActionFinish));
              break;
            case kTransferCommandActionClose:
              i('${command.action} command: close receiver socket');
              close();
              break;
            case kTransferCommandActionStart:
              i('${command.action} command: start receiver');
              _total = command.total!;
              onReceiverStart?.call();
              onReceiverProgressUpdate?.call(0);
              break;
          }
          break;
        case JsonTransferDataType.expiredMessage:
          final expiredMessage = TransferDataExpiredMessage.fromJson(data.data);
          d('client: expiredMessage: $expiredMessage');
          await database.expiredMessageDao.insert(
            messageId: expiredMessage.messageId,
            expireIn: expiredMessage.expireIn,
            expireAt: expiredMessage.expireAt,
            updateIfConflict: false,
          );
          break;
        case JsonTransferDataType.transcriptMessage:
          final transcriptMessage =
              TransferDataTranscriptMessage.fromJson(data.data);
          d('client: transcriptMessage: $transcriptMessage');
          await database.transcriptMessageDao.insertAll(
            [transcriptMessage.toDbTranscriptMessage()],
            mode: InsertMode.insertOrIgnore,
          );
          break;
        case JsonTransferDataType.participant:
          final participant = TransferDataParticipant.fromJson(data.data);
          d('client: participant: $participant');
          await database.participantDao.insert(
            participant.toDbParticipant(),
            updateIfConflict: false,
          );
          break;
        case JsonTransferDataType.pinMessage:
          final pinMessage = TransferDataPinMessage.fromJson(data.data);
          d('client: pinMessage: $pinMessage');
          await database.pinMessageDao.insert(
            pinMessage.toDbPinMessage(),
            updateIfConflict: false,
          );
          break;
        case JsonTransferDataType.messageMention:
          final messageMention = MessageMention.fromJson(data.data);
          d('client: messageMention: $messageMention');
          await database.messageMentionDao.insert(
            messageMention,
            updateIfConflict: false,
          );
          break;
        case JsonTransferDataType.app:
          final app = TransferDataApp.fromJson(data.data);
          d('client: app: $app');
          await database.appDao.insert(
            app.toDbApp(),
            updateIfConflict: false,
          );
          break;
        case JsonTransferDataType.unknown:
          i('unknown type: ${data.type}');
          break;
      }
    } catch (error, stacktrace) {
      e('_processReceivedJsonPacket: ${data.data}');
      e('_processReceivedJsonPacket', error, stacktrace);
    }
  }

  Future<void> _processReceivedAttachmentPacket(
      TransferAttachmentPacket packet) async {
    d('_processReceivedAttachmentPacket: ${packet.messageId} ${packet.path}');

    void deletePacketFile() {
      try {
        File(packet.path).deleteSync();
      } catch (error) {
        e('_processReceivedAttachmentPacket: deletePacketFile', error);
      }
    }

    String? path;
    final message =
        await database.messageDao.findMessageByMessageId(packet.messageId);
    if (message != null) {
      path = attachmentUtil.convertAbsolutePath(
        category: message.category,
        conversationId: message.conversationId,
        fileName: message.mediaUrl,
      );
    } else {
      final tm = await database.transcriptMessageDao
          .transcriptMessageByMessageId(packet.messageId)
          .getSingleOrNull();
      if (tm == null) {
        e('_processReceivedAttachmentPacket: message not found ${packet.messageId}');
        deletePacketFile();
        return;
      }
      path = attachmentUtil.convertAbsolutePath(
        category: tm.category,
        fileName: tm.mediaUrl,
        isTranscript: true,
      );
    }

    if (path.isEmpty) {
      e('_processReceivedAttachmentPacket: path is empty');
      deletePacketFile();
      return;
    }

    final file = File(path);
    if (file.existsSync()) {
      // already exist
      i('_processReceivedAttachmentPacket: already exist');
      deletePacketFile();
      return;
    }
    // check file parent folder
    final parent = file.parent;
    if (!parent.existsSync()) {
      parent.createSync(recursive: true);
    }

    try {
      File(packet.path).renameSync(file.path);
    } catch (error, stacktrace) {
      e('_processReceivedAttachmentPacket: $error $stacktrace');
    }
  }

  void close() {
    _socket?.destroy();
    _socket = null;
  }
}