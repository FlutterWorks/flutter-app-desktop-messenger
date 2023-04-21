import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:ansicolor/ansicolor.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter/services.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:rxdart/rxdart.dart';
import 'package:stream_channel/isolate_channel.dart';

import '../blaze/blaze_message.dart';
import '../blaze/vo/plain_json_message.dart';
import '../constants/constants.dart';
import '../db/database.dart';
import '../db/fts_database.dart';
import '../db/mixin_database.dart';
import '../utils/attachment/attachment_util.dart';
import '../utils/device_transfer/device_transfer_receiver.dart';
import '../utils/device_transfer/device_transfer_sender.dart';
import '../utils/device_transfer/device_transfer_widget.dart';
import '../utils/device_transfer/transfer_data_command.dart';
import '../utils/device_transfer/transfer_protocol.dart';
import '../utils/event_bus.dart';
import '../utils/file.dart';
import '../utils/load_balancer_utils.dart';
import '../utils/logger.dart';
import '../utils/platform.dart';

typedef MessageDeliver = void Function(BlazeMessage blazeMessage);

class DeviceTransferStartParams {
  DeviceTransferStartParams({
    required this.identityNumber,
    required this.userId,
    required this.primarySessionId,
    required this.rootIsolateToken,
    required this.mixinDocumentDirectory,
    required this.sendPort,
  });

  final String identityNumber;
  final String userId;
  final String? primarySessionId;
  final ui.RootIsolateToken rootIsolateToken;
  final String mixinDocumentDirectory;
  final SendPort sendPort;
}

class DeviceTransferIsolateMessage {}

class DeviceTransferIsolateDeliverMessage
    implements DeviceTransferIsolateMessage {
  DeviceTransferIsolateDeliverMessage(this.message);

  final BlazeMessage message;
}

class DeviceTransferIsolateDestroy implements DeviceTransferIsolateMessage {}

class DeviceTransferIsolateHandleCommand
    implements DeviceTransferIsolateMessage {
  DeviceTransferIsolateHandleCommand(this.command);

  final TransferDataCommand command;
}

class DeviceTransferIsolateController {
  DeviceTransferIsolateController({
    required this.dispose,
    required this.handleRemoteCommand,
  });

  final void Function() dispose;

  final void Function(TransferDataCommand command) handleRemoteCommand;
}

Future<DeviceTransferIsolateController> startTransferIsolate({
  required String identityNumber,
  required String userId,
  required String primarySessionId,
  required ui.RootIsolateToken rootIsolateToken,
  required MessageDeliver messageDeliver,
  required String mixinDocumentDirectory,
}) async {
  final receivePort = ReceivePort();
  final isolateChannel = IsolateChannel<dynamic>.connectReceive(receivePort);
  final exitReceivePort = ReceivePort();
  final errorReceivePort = ReceivePort();
  await Isolate.spawn(
    _deviceTransferIsolateEntryPoint,
    DeviceTransferStartParams(
      identityNumber: identityNumber,
      userId: userId,
      primarySessionId: primarySessionId,
      rootIsolateToken: rootIsolateToken,
      mixinDocumentDirectory: mixinDocumentDirectory,
      sendPort: receivePort.sendPort,
    ),
    debugName: 'device_transfer',
    errorsAreFatal: false,
    onExit: exitReceivePort.sendPort,
    onError: errorReceivePort.sendPort,
  );
  final jobSubscribers = <StreamSubscription>{}
    ..add(exitReceivePort.listen((message) {
      w('device transfer isolate exit: $message');
    }))
    ..add(errorReceivePort.listen((message) {
      w('device transfer isolate error: $message');
    }))
    ..add(isolateChannel.stream.listen((message) {
      if (message is DeviceTransferIsolateDeliverMessage) {
        messageDeliver(message.message);
      }
    }));

  return DeviceTransferIsolateController(
    dispose: () {
      isolateChannel.sink.add(DeviceTransferIsolateDestroy());
      jobSubscribers.forEach((element) => element.cancel());
      receivePort.close();
      exitReceivePort.close();
      errorReceivePort.close();
    },
    handleRemoteCommand: (command) {
      isolateChannel.sink.add(DeviceTransferIsolateHandleCommand(command));
    },
  );
}

Future<void> _deviceTransferIsolateEntryPoint(
    DeviceTransferStartParams params) async {
  EquatableConfig.stringify = true;
  ansiColorDisabled = Platform.isIOS;
  mixinDocumentsDirectory = Directory(params.mixinDocumentDirectory);
  BackgroundIsolateBinaryMessenger.ensureInitialized(params.rootIsolateToken);

  final isolateChannel =
      IsolateChannel<DeviceTransferIsolateMessage>.connectSend(params.sendPort);

  final database = Database(
    await connectToDatabase(params.identityNumber, readCount: 1),
    await FtsDatabase.connect(params.identityNumber),
  );
  final deviceTransfer = await DeviceTransfer.create(
    database: database,
    userId: params.userId,
    messageDeliver: (message) async {
      isolateChannel.sink.add(DeviceTransferIsolateDeliverMessage(message));
    },
    primarySessionId: params.primarySessionId,
    identityNumber: params.identityNumber,
  );

  isolateChannel.stream.listen((event) {
    i('device transfer isolate receive event: $event');
    if (event is DeviceTransferIsolateDestroy) {
      deviceTransfer.dispose();
      Isolate.exit();
    } else if (event is DeviceTransferIsolateHandleCommand) {
      deviceTransfer.handleRemoteCommand(event.command);
    }
  });
}

class DeviceTransfer {
  DeviceTransfer({
    required this.database,
    required this.userId,
    required this.messageDeliver,
    required this.primarySessionId,
    required this.sender,
    required this.receiver,
  }) {
    _subscriptions.add(EventBus.instance.on
        .whereType<DeviceTransferCommand>()
        .listen((event) async {
      switch (event) {
        case DeviceTransferCommand.pullToRemote:
          await _sendPullToOtherSession();
          break;
        case DeviceTransferCommand.pushToRemote:
          await _sendPushToOtherSession();
          break;
        case DeviceTransferCommand.cancelRestore:
          receiver.close();
          break;
        case DeviceTransferCommand.cancelBackup:
          sender.close();
          break;
        case DeviceTransferCommand.confirmRestore:
          final data = _remotePushData;
          if (data == null) {
            e('confirm restore but no data.');
            return;
          }
          _remotePushData = null;
          await receiver.connectToServer(data.ip, data.port, data.code);
          break;
        case DeviceTransferCommand.confirmBackup:
          await _sendPushToOtherSession();
          break;
      }
    }));
  }

  static Future<DeviceTransfer> create({
    required Database database,
    required String userId,
    required MessageDeliver messageDeliver,
    required String? primarySessionId,
    required String identityNumber,
  }) async {
    final attachmentUtil = AttachmentUtilBase.of(identityNumber);
    final transform = await _getProtocolTransform();
    final deviceId = await getDeviceId();
    final sender = DeviceTransferSender(
      database: database,
      attachmentUtil: attachmentUtil,
      protocolTransform: transform,
      deviceId: deviceId,
      onSenderStart: () {
        DeviceTransferEventBus.instance
            .fire(DeviceTransferCallbackType.onBackupStart);
      },
      onSenderSucceed: () {
        DeviceTransferEventBus.instance
            .fire(DeviceTransferCallbackType.onBackupSucceed);
      },
      onSenderFailed: () {
        DeviceTransferEventBus.instance
            .fire(DeviceTransferCallbackType.onBackupFailed);
      },
      onSenderProgressUpdate: (progress) {
        DeviceTransferEventBus.instance.fire(
          DeviceTransferCallbackType.onBackupProgress,
          progress,
        );
      },
    );
    final receiver = DeviceTransferReceiver(
      database: database,
      userId: userId,
      attachmentUtil: attachmentUtil,
      protocolTransform: transform,
      deviceId: deviceId,
      onReceiverStart: () {
        DeviceTransferEventBus.instance
            .fire(DeviceTransferCallbackType.onRestoreStart);
      },
      onReceiverSucceed: () {
        DeviceTransferEventBus.instance
            .fire(DeviceTransferCallbackType.onRestoreSucceed);
      },
      onReceiverFailed: () {
        DeviceTransferEventBus.instance
            .fire(DeviceTransferCallbackType.onRestoreFailed);
      },
      onReceiverProgressUpdate: (progress) {
        DeviceTransferEventBus.instance.fire(
          DeviceTransferCallbackType.onRestoreProgress,
          progress,
        );
      },
    );

    return DeviceTransfer(
      database: database,
      userId: userId,
      messageDeliver: messageDeliver,
      primarySessionId: primarySessionId,
      sender: sender,
      receiver: receiver,
    );
  }

  final Database database;
  final String userId;
  final MessageDeliver messageDeliver;
  final String? primarySessionId;

  final DeviceTransferSender sender;
  final DeviceTransferReceiver receiver;

  final List<StreamSubscription> _subscriptions = [];

  _RemotePushData? _remotePushData;

  // Current device already sent a pull event to remote.
  // If remote device is online, it will send a push event to current device.
  var _waitingForRemotePush = false;

  Future<void> _sendCommandAsPlainJson(TransferDataCommand command) async {
    final conversationId =
        await database.participantDao.findJoinedConversationId(userId);
    if (conversationId == null) {
      e('_sendDeviceTransferToOtherSession: conversationId is null');
      return;
    }

    final content = await jsonEncodeWithIsolate(command.toJson());
    final plainText = PlainJsonMessage.create(
      action: kDeviceTransfer,
      content: content,
    );
    final encoded = await base64EncodeWithIsolate(
        await utf8EncodeWithIsolate(await jsonEncodeWithIsolate(plainText)));
    final param = createPlainJsonParam(
      conversationId,
      userId,
      encoded,
      sessionId: primarySessionId,
    );
    final bm = createParamBlazeMessage(param);
    messageDeliver(bm);
  }

  Future<void> _sendPullToOtherSession() async {
    _waitingForRemotePush = true;
    final command = TransferDataCommand.pull(deviceId: await getDeviceId());
    await _sendCommandAsPlainJson(command);
  }

  static Future<TransferProtocolTransform> _getProtocolTransform() async {
    final fileFolder = await getTemporaryDirectory();
    final folder = p.join(fileFolder.path, 'mixin_transfer');
    try {
      await Directory(folder).create(recursive: true);
    } catch (error, stacktrace) {
      e('create folder error: $error $stacktrace');
    }
    return TransferProtocolTransform(fileFolder: folder);
  }

  Future<void> _sendPushToOtherSession() async {
    String? ipAddress;
    try {
      ipAddress = await NetworkInfo().getWifiIP();
    } catch (error) {
      assert(() {
        // for test
        ipAddress = '0.0.0.0';
        return true;
      }());
    }
    if (ipAddress == null) {
      e('_sendPushToOtherSession: ipAddress is null');
      return;
    }

    final code = Random().nextInt(10000);

    final port = await sender.startServerSocket(code);
    i('_sendPushToOtherSession: server addr $ipAddress:$port');

    final command = TransferDataCommand.push(
      ip: ipAddress!,
      port: port,
      deviceId: await getDeviceId(),
      code: code,
    );

    await _sendCommandAsPlainJson(command);
  }

  void handleRemoteCommand(TransferDataCommand command) {
    d('handleRemoteCommand: $command');
    if (command.version != kDeviceTransferProtocolVersion) {
      e('command version not matched');
      DeviceTransferEventBus.instance.fire(
        DeviceTransferCallbackType.onCommandVersionNotMatched,
        command.version,
      );
      return;
    }
    switch (command.action) {
      case kTransferCommandActionPush:
        _handleRemotePushCommand(command.ip!, command.port!, command.code!);
        break;
      case kTransferCommandActionPull:
        DeviceTransferEventBus.instance
            .fire(DeviceTransferCallbackType.onRestoreRequestReceived);
        break;
      default:
        e('handleRemoteCommand: unknown action ${command.action}');
        return;
    }
  }

  Future<void> _handleRemotePushCommand(String ip, int port, int code) async {
    d('_handleRemotePushCommand: $ip:$port ($code)');
    if (_waitingForRemotePush) {
      _waitingForRemotePush = false;
      await receiver.connectToServer(ip, port, code);
    } else {
      _remotePushData = _RemotePushData(ip: ip, port: port, code: code);
      DeviceTransferEventBus.instance
          .fire(DeviceTransferCallbackType.onBackupRequestReceived);
    }
  }

  void dispose() {
    d('dispose: device transfer');
    _remotePushData = null;
    _subscriptions
      ..forEach((s) => s.cancel())
      ..clear();
    sender.close();
    receiver.close();
  }
}

class _RemotePushData {
  _RemotePushData({
    required this.ip,
    required this.port,
    required this.code,
  });

  final String ip;
  final int port;
  final int code;
}