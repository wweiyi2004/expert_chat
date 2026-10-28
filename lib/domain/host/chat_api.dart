import '../../state/chat_controller.dart';
import '../../data/models.dart';
import '../../data/story_models.dart';
import '../../data/db/app_database.dart' show GenerationRecord;
import '../study/tutor_style.dart';
import '../llm/llm_provider.dart';
import '../../features/tui_bridge/protocol.dart';
import 'wire_models.dart';

/// Human-client commands retain the same controller implementation and scope.
class HostChatApi {
  HostChatApi(this.controller, this.currentState);
  final ChatController controller;
  final ChatState Function() currentState;
  Future<Object?> invoke(
    String operation,
    Map<String, dynamic> a,
    String? session,
  ) => controller.runHostCall(
    session,
    () async {
      String text(String key) => a[key] as String? ?? '';
      String id(String key) => requiredString(a, key);
      List<String>? optionalStrings(String key) =>
          (a[key] as List?)?.cast<String>();
      List<Attachment> attachments(String key) =>
          wireRows(a[key]).map(Attachment.fromJson).toList();
      List<CharacterCard> cast() =>
          wireRows(a['cast']).map(CharacterCard.fromJson).toList();
      switch (operation) {
        case 'sendMessage':
          return controller.sendMessage(
            text('text'),
            attachments: attachments('attachments'),
            forceDocumentEdit: a['forceDocumentEdit'] == true,
          );
        case 'sendToSession':
          return controller.sendToSession(
            id('id'),
            text('text'),
            attachments: attachments('attachments'),
            automaticTitle: a['automaticTitle'] == true,
          );
        case 'sendLongDocumentTask':
          return controller.sendLongDocumentTask(
            text('text'),
            attachments: attachments('attachments'),
          );
        case 'generateImage':
          return controller.generateImage(
            text('prompt'),
            referenceImages: attachments('referenceImages'),
          );
        case 'regenerateImageVersion':
          return controller.regenerateImageVersion(
            GenerationRecord.fromJson(wireMap(a['record'])),
          );
        case 'newConversation':
          controller.newConversation(
            projectId: a['projectId'] as String?,
            workMode: a['workMode'] == true,
            forceNew: a['forceNew'] == true,
          );
          final created = currentState().currentId!;
          await controller.persistHostSession(created);
          return created;
        case 'createWorkSession':
          return controller.createWorkSession(title: a['title'] as String?);
        case 'newStudyConversation':
          return (await controller.newStudyConversation(
            topic: text('topic'),
            tutorStyle: wireEnum(
              TutorStyle.values,
              a['tutorStyle'],
              TutorStyle.mixed,
            ),
            path: wireEnum(StudyPath.values, a['path'], StudyPath.tutor),
            courseId: a['courseId'] as String?,
            nodeId: a['nodeId'] as String?,
            opener: a['opener'] as String?,
          )).toJson();
        case 'newStoryConversation':
          return controller.captureHostSelection(
            () => controller.newStoryConversation(
              CharacterCard.fromJson(wireMap(a['card'])),
              worldInfoIds: optionalStrings('worldInfoIds'),
            ),
          );
        case 'newDirectorStoryConversation':
          return controller.captureHostSelection(
            () => controller.newDirectorStoryConversation(
              title: text('title'),
              premise: text('premise'),
              cast: cast(),
              outline: text('outline'),
              authorNote: text('authorNote'),
              requirements: text('requirements'),
              worldInfoIds: optionalStrings('worldInfoIds'),
              targetTotalChars: a['targetTotalChars'] as int? ?? 0,
            ),
          );
        case 'newEnsembleConversation':
          return controller.captureHostSelection(
            () => controller.newEnsembleConversation(
              cast: cast(),
              venue: text('venue'),
              authorNote: text('authorNote'),
              worldInfoIds: optionalStrings('worldInfoIds'),
            ),
          );
        case 'assignProject':
          await controller.assignProject(
            id('conversationId'),
            a['projectId'] as String?,
          );
        case 'deleteProject':
          await controller.deleteProject(id('projectId'));
        case 'updateStoryMeta':
          controller.updateStoryMeta(
            conversationId: a['conversationId'] as String? ?? session,
            outline: a['outline'] as String?,
            authorNote: a['authorNote'] as String?,
            worldInfoIds: optionalStrings('worldInfoIds'),
            plotCursor: a['plotCursor'] as int?,
            venue: a['venue'] as String?,
            participantIds: optionalStrings('participantIds'),
            nextSpeakerIndex: a['nextSpeakerIndex'] as int?,
            targetTotalChars: a['targetTotalChars'] as int?,
          );
        case 'adjustPlotCursor':
          controller.adjustPlotCursor(a['delta'] as int);
        case 'advancePlot':
          await controller.advancePlot();
        case 'continueCurrentScene':
          await controller.continueCurrentScene();
        case 'ensembleNextTurn':
          await controller.ensembleNextTurn(
            forceCharacterId: a['forceCharacterId'] as String?,
            conversationId: a['conversationId'] as String? ?? session,
          );
        case 'ensembleAutoPlay':
          await controller.ensembleAutoPlay(rounds: a['rounds'] as int? ?? 6);
        case 'toggleDeepThink':
          controller.toggleDeepThink();
        case 'setReasoningEffort':
          controller.setReasoningEffort(
            ReasoningEffort.values.byName(id('effort')),
          );
        case 'toggleSearch':
          controller.toggleSearch();
        case 'applyComposerPrefs':
          controller.applyComposerPrefs(
            searchMode: SearchMode.values.byName(id('searchMode')),
            imageGenMode: ImageGenMode.values.byName(id('imageGenMode')),
            reasoningEffort: ReasoningEffort.values.byName(
              id('reasoningEffort'),
            ),
          );
        case 'toggleImageGenMode':
          controller.toggleImageGenMode();
        case 'setImageGenMode':
          controller.setImageGenMode(ImageGenMode.values.byName(id('mode')));
        case 'switchConversationMode':
          controller.switchConversationMode(a['enabled'] as bool);
        case 'setWorkMode':
          controller.setWorkMode(a['enabled'] as bool);
        case 'setCustomMcpServerIds':
          controller.setCustomMcpServerIds(optionalStrings('ids') ?? []);
        case 'setSessionMcpSelection':
          await controller.setSessionMcpSelection(
            id('id'),
            optionalStrings('selected') ?? [],
          );
        case 'renameConversation':
          controller.renameConversation(id('id'), text('title'));
        case 'deleteConversation':
          await controller.deleteConversation(id('id'));
        case 'stop':
          controller.stop(
            persist: a['persist'] != false,
            conversationId: a['conversationId'] as String? ?? session,
          );
        case 'stopAndWait':
          await controller.stopAndWait(
            persist: a['persist'] != false,
            conversationId: a['conversationId'] as String? ?? session,
          );
        case 'sendWorkContinuation':
          return controller.sendWorkContinuation(
            id('conversationId'),
            a['rounds'] as int,
          );
        case 'cancelLongTask':
          await controller.cancelLongTask(id('convoId'), id('assistantId'));
        case 'retryLongTask':
          await controller.retryLongTask(id('convoId'), id('assistantId'));
        case 'editMessage':
          await controller.editMessage(
            id('messageId'),
            text('newText'),
            attachments: a['attachments'] == null
                ? null
                : attachments('attachments'),
          );
        case 'regenerate':
          await controller.regenerate(
            retryOperation: decodeRetry(a['retryOperation']),
          );
        case 'switchBranch':
          controller.switchBranch(id('messageId'), a['delta'] as int);
        case 'retryLast':
          await controller.retryLast();
        case 'requestTaskAnswer':
          controller.requestTaskAnswer(id('convoId'), id('msgId'));
        case 'answerFromResults':
          await controller.answerFromResults(id('convoId'), id('msgId'));
        case 'retryTaskStep':
          await controller.retryTaskStep(
            id('convoId'),
            id('msgId'),
            id('stepId'),
            confirmedPaidRequest: a['confirmedPaidRequest'] == true,
          );
        case 'verifyAndAcceptTask':
          return controller.verifyAndAcceptTask(id('conversationId'));
        case 'addWorkRequirement':
          return controller.addWorkRequirement(
            id('conversation'),
            text('text'),
          );
        case 'withdrawWorkRequirement':
          return controller.withdrawWorkRequirement(id('id'), id('queuedId'));
        case 'resumeChildTask':
          return controller.resumeChildTask(
            id('conversationId'),
            id('agentId'),
          );
        case 'resumeSessionTask':
          return controller.resumeSessionTask(id('conversationId'));
        case 'compactSessionContext':
          return controller.compactSessionContext(id('id'));
        case 'configureSessionThinking':
          controller.configureSessionThinking(
            id('id'),
            a['thinking'] as bool,
            ReasoningEffort.values.byName(id('effort')),
          );
        case 'requestAutomaticTitleForSession':
          controller.requestAutomaticTitleForSession(id('id'));
        case 'dismissError':
          controller.dismissError(
            conversationId: a['conversationId'] as String? ?? session,
          );
        case 'reportExternalFailure':
          controller.reportExternalFailure(id('id'), text('message'));
        case 'flushSessionCheckpointWrites':
          await controller.flushSessionCheckpointWrites();
        case 'prepareDataMaintenance':
          await controller.prepareDataMaintenance();
        default:
          throw const BridgeFailure('unsupported', '未注册的会话操作');
      }
      if (session != null &&
          currentState().conversations.any((c) => c.id == session) &&
          !controller.isConversationRunning(session)) {
        await controller.persistHostSession(session);
      }
      return null;
    },
    global:
        operation.startsWith('new') ||
        const {
          'createWorkSession',
          'assignProject',
          'deleteProject',
          'renameConversation',
          'deleteConversation',
          'prepareDataMaintenance',
        }.contains(operation),
  );
}
