export class ApiResponseValidator {
  private static isSharedFocus(payload: Record<string, Object>): boolean {
    if (!['userId', 'deviceId'].every((key: string) => ApiResponseValidator.hasString(payload, key)) ||
      !ApiResponseValidator.hasNumber(payload, 'serverTime')) return false;
    if (payload['session'] === null) return true;
    if (!ApiResponseValidator.isRecord(payload['session'])) return false;
    const session = payload['session'] as Record<string, Object>;
    if (!['sessionId', 'leaderDeviceId', 'leaderLabel'].every((key: string) => ApiResponseValidator.hasString(session, key)) ||
      !['revision', 'elapsedMs', 'remainingMs', 'startedAt', 'updatedAt'].every((key: string) => ApiResponseValidator.hasNumber(session, key)) ||
      !['running', 'paused', 'completed', 'abandoned'].includes(session['state'] as string) ||
      !ApiResponseValidator.hasArray(session, 'participants') || !ApiResponseValidator.isRecord(session['task']) ||
      !ApiResponseValidator.isRecord(session['lastEvent'])) return false;
    const task = session['task'] as Record<string, Object>;
    return ['course', 'task'].every((key: string) => ApiResponseValidator.hasString(task, key)) &&
      ApiResponseValidator.hasNumber(task, 'plannedMinutes') &&
      ['normal', 'strict'].includes(task['mode'] as string) &&
      ['countdown', 'stopwatch'].includes(task['timerType'] as string) &&
      (session['participants'] as Object[]).every((value: Object) => {
        if (!ApiResponseValidator.isRecord(value)) return false;
        const participant = value as Record<string, Object>;
        return ['deviceId', 'deviceLabel', 'role'].every((key: string) => ApiResponseValidator.hasString(participant, key)) &&
          ApiResponseValidator.hasNumber(participant, 'lastSeen') && ApiResponseValidator.hasBoolean(participant, 'online') &&
          ApiResponseValidator.hasBoolean(participant, 'background');
      });
  }
  private static isCollaboration(payload: Record<string, Object>): boolean {
    if (!['userId', 'deviceId'].every((key: string) => ApiResponseValidator.hasString(payload, key)) ||
      !ApiResponseValidator.hasNumber(payload, 'serverTime') || !ApiResponseValidator.hasArray(payload, 'devices') ||
      !ApiResponseValidator.hasArray(payload, 'links')) return false;
    if (!(payload['devices'] as Object[]).every((item: Object) => {
      if (!ApiResponseValidator.isRecord(item)) return false;
      const row = item as Record<string, Object>;
      return ['deviceId', 'deviceLabel'].every((key: string) => ApiResponseValidator.hasString(row, key)) &&
        ApiResponseValidator.hasBoolean(row, 'online') && ApiResponseValidator.hasNumber(row, 'lastSeen');
    })) return false;
    return (payload['links'] as Object[]).every((item: Object) => {
      if (!ApiResponseValidator.isRecord(item)) return false;
      const row = item as Record<string, Object>;
      if (!['invitationId', 'peerDeviceId', 'peerDeviceLabel', 'state'].every((key: string) => ApiResponseValidator.hasString(row, key)) ||
        !ApiResponseValidator.isString(row, 'sentMessageId') || !ApiResponseValidator.hasBoolean(row, 'incoming') ||
        !['expiresAt', 'acknowledgedAt'].every((key: string) => ApiResponseValidator.hasNumber(row, key)) ||
        !['pending', 'connected', 'expired', 'rejected', 'disconnected'].includes(row['state'] as string)) return false;
      if (row['received'] === null) return true;
      if (!ApiResponseValidator.isRecord(row['received'])) return false;
      const message = row['received'] as Record<string, Object>;
      if (!ApiResponseValidator.hasString(message, 'messageId') ||
        !['sentAt', 'ackedAt'].every((key: string) => ApiResponseValidator.hasNumber(message, key))) return false;
      if (message['task'] === null) return true;
      if (!ApiResponseValidator.isRecord(message['task'])) return false;
      const task = message['task'] as Record<string, Object>;
      return ['course', 'task'].every((key: string) => ApiResponseValidator.hasString(task, key)) &&
        ApiResponseValidator.hasNumber(task, 'plannedMinutes') && (task['plannedMinutes'] as number) >= 0 &&
        (task['plannedMinutes'] as number) <= 180 && ['normal', 'strict'].includes(task['mode'] as string) &&
        ['stopwatch', 'countdown'].includes(task['timerType'] as string) && task['source'] === 'collaborative' &&
        ApiResponseValidator.hasBoolean(task, 'allowBackgroundTiming');
    });
  }
  private static isReminder(payload: Object): boolean {
    if (!ApiResponseValidator.isRecord(payload)) return false;
    const data: Record<string, Object> = payload as Record<string, Object>;
    return ['eventId', 'userId', 'kind', 'objectId', 'title', 'level', 'status', 'reason',
      'targetPage', 'dataTime'].every((key: string) => ApiResponseValidator.hasString(data, key)) &&
      ['courseName', 'planId', 'knowledgePointId'].every((key: string) => ApiResponseValidator.isString(data, key)) &&
      ['task', 'exam', 'gap', 'conflict'].includes(data['kind'] as string) &&
      ['pending', 'started', 'snoozed', 'ignored', 'completed', 'invalid'].includes(data['status'] as string) &&
      ApiResponseValidator.hasNumber(data, 'version') && ApiResponseValidator.hasNumber(data, 'sourceVersion') &&
      ApiResponseValidator.hasNumber(data, 'durationMinutes');
  }
  private static basePath(path: string): string {
    const mark: number = path.indexOf('?');
    return mark >= 0 ? path.substring(0, mark) : path;
  }

  static isValid(method: string, path: string, payload: Object): boolean {
    if (!ApiResponseValidator.isRecord(payload)) {
      return false;
    }
    const data: Record<string, Object> = payload as Record<string, Object>;
    const route: string = ApiResponseValidator.basePath(path);
    if (route === '/ready') return method === 'GET' && data['status'] === 'ready';
    if (route === '/api/v1/focus-session') return ApiResponseValidator.isSharedFocus(data);
    if (route === '/api/v1/focus-session/actions') return ApiResponseValidator.isSharedFocus(data);
    if (route === '/api/v1/plans/current/today-items') return ApiResponseValidator.isPlan(data);
    if (route === '/api/v1/chat-files') return ApiResponseValidator.hasString(data, 'fileName') &&
      ApiResponseValidator.hasString(data, 'text') && ApiResponseValidator.hasBoolean(data, 'truncated');
    if (route === '/api/v1/study-tasks') return ApiResponseValidator.isPlan(data);
    if (route === '/api/v1/shared-study-tasks') return ApiResponseValidator.hasArray(data, 'tasks') &&
      (data['tasks'] as Object[]).every((value: Object) => {
        if (!ApiResponseValidator.isRecord(value)) return false;
        const item = value as Record<string, Object>;
        return ['taskId','title','courseName','scheduledDate','fromUserId','partnerId','partnerName','myPart','partnerPart'].every((key: string) => ApiResponseValidator.hasString(item, key)) &&
          ['pending','accepted','declined'].includes(item['status'] as string) &&
          ['pending','completed'].includes(item['myStatus'] as string) && ['pending','completed'].includes(item['partnerStatus'] as string) &&
          ApiResponseValidator.hasNumber(item, 'durationMinutes');
      });
    if (route === '/api/v1/device-collaboration') return method === 'POST' && ApiResponseValidator.isCollaboration(data);
    if (route === '/api/v1/learning-data') return ApiResponseValidator.hasString(data, 'userId') &&
      ApiResponseValidator.hasNumber(data, 'revision') && ApiResponseValidator.hasArray(data, 'courses') &&
      ApiResponseValidator.hasArray(data, 'homeworkDDLs') &&
      (data['courses'] as Object[]).every((item: Object) => ApiResponseValidator.isRecord(item) &&
        ApiResponseValidator.hasString(item as Record<string, Object>, 'courseId') &&
        ApiResponseValidator.hasString(item as Record<string, Object>, 'courseName') &&
        ApiResponseValidator.isRecordField(item as Record<string, Object>, 'exam') &&
        ApiResponseValidator.isRecordField(item as Record<string, Object>, 'recentStatus') &&
        ApiResponseValidator.hasNumber(item as Record<string, Object>, 'syncVersion')) &&
      (data['homeworkDDLs'] as Object[]).every((item: Object) => ApiResponseValidator.isRecord(item) &&
        ['id', 'courseName', 'title', 'dueDate'].every((key: string) => ApiResponseValidator.hasString(item as Record<string, Object>, key)) &&
        ['syncVersion', 'estimatedMinutes', 'daysLeft'].every((key: string) => ApiResponseValidator.hasNumber(item as Record<string, Object>, key)));
    if (route === '/api/v1/learning-effect') return ApiResponseValidator.hasString(data, 'userId') &&
      ApiResponseValidator.hasString(data, 'conclusion') && ApiResponseValidator.hasString(data, 'ruleVersion') &&
      ['days', 'focusMinutes', 'completedFocusSessions', 'answeredCount', 'correctCount'].every((key: string) => ApiResponseValidator.hasNumber(data, key)) &&
      (data['practiceAccuracy'] === null || ApiResponseValidator.hasNumber(data, 'practiceAccuracy')) &&
      ApiResponseValidator.hasArray(data, 'points');
    if (route === '/api/v1/today') return ApiResponseValidator.hasString(data, 'userId') &&
      ApiResponseValidator.hasString(data, 'dataTime') && ApiResponseValidator.hasString(data, 'version') &&
      ApiResponseValidator.hasNumber(data, 'pendingCount') && ApiResponseValidator.hasString(data, 'guidance') &&
      ApiResponseValidator.hasArray(data, 'tasks') && (data['tasks'] as Object[]).every((item: Object) => ApiResponseValidator.isReminder(item)) &&
      (data['allTasks'] === undefined || (ApiResponseValidator.hasArray(data, 'allTasks') && (data['allTasks'] as Object[]).every((item: Object) => ApiResponseValidator.isReminder(item)))) &&
      (data['highlight'] === null || ApiResponseValidator.isReminder(data['highlight']));
    if (route === '/api/v1/reminders') return ApiResponseValidator.hasArray(data, 'events') &&
      (data['events'] as Object[]).every((item: Object) => ApiResponseValidator.isReminder(item)) &&
      ApiResponseValidator.isString(data, 'cursor') && ApiResponseValidator.hasBoolean(data, 'hasMore');
    if (method === 'GET' && route.indexOf('/api/v1/reminders/') === 0 && route.indexOf('/actions/') > 0) return ApiResponseValidator.isReminder(data['event']);
    if (method === 'POST' && route.indexOf('/api/v1/reminders/') === 0 && route.endsWith('/actions')) return ApiResponseValidator.isReminder(data['event']);
    if (route === '/api/v1/reminder-preferences') {
      if (!ApiResponseValidator.isRecordField(data, 'preferences') || !ApiResponseValidator.hasBoolean(data, 'pushConfigured')) return false;
      const prefs: Record<string, Object> = data['preferences'] as Record<string, Object>;
      if (prefs['categories'] !== undefined && (!ApiResponseValidator.hasArray(prefs, 'categories') ||
        !(prefs['categories'] as Object[]).every((item: Object) => typeof item === 'string' && ['task', 'exam', 'gap', 'conflict'].includes(item as string)))) return false;
      return ApiResponseValidator.hasBoolean(prefs, 'enabled') && ApiResponseValidator.hasBoolean(prefs, 'urgentException') &&
        ApiResponseValidator.hasString(prefs, 'timezone') && ['quietStart', 'quietEnd', 'dailyLimit', 'minimumGapMinutes', 'summaryHour']
          .every((key: string) => ApiResponseValidator.hasNumber(prefs, key));
    }
    if (route === '/api/v1/reminder-devices') return method === 'GET' ? ApiResponseValidator.hasArray(data, 'devices') :
      method === 'DELETE' ? ApiResponseValidator.hasString(data, 'status') : ApiResponseValidator.hasString(data, 'deviceId') && ApiResponseValidator.hasBoolean(data, 'active');
    if (route === '/api/v1/plans/current/tasks/split') return ApiResponseValidator.isPlan(data);
    if (route === '/api/v1/plans/current/recommendation') return ApiResponseValidator.isPlan(data);
    if (route === '/api/v1/plans/current/calendar') return ApiResponseValidator.isPlan(data);
    if (method === 'PUT' && route.indexOf('/api/v1/profile/') === 0 && route.endsWith('/knowledge-points/classification')) return ApiResponseValidator.hasNumber(data, 'profileVersion') && ApiResponseValidator.hasArray(data, 'mastery');
    if (route === '/api/v1/learning-course-settings') return ApiResponseValidator.hasArray(data, 'courses');
    if (route === '/api/v1/partner-conversations') return ApiResponseValidator.hasArray(data, 'conversations') && ApiResponseValidator.hasNumber(data, 'totalUnread');
    if (route.endsWith('/summary') && route.indexOf('/api/v1/partners/') === 0) return ApiResponseValidator.isRecordField(data, 'conversation');
    if (route.endsWith('/read') && route.indexOf('/api/v1/partners/') === 0) return ApiResponseValidator.hasString(data, 'lastReadMessageId');
    if (method === 'POST' && route.endsWith('/end') && route.indexOf('/api/v1/partners/') === 0) return data['status'] === 'ended';
    if (method === 'GET' && route.indexOf('/api/v1/partners/') === 0) {
      return ApiResponseValidator.hasArray(data, 'messages') && ApiResponseValidator.hasString(data, 'cursor') && ApiResponseValidator.hasBoolean(data, 'hasMore');
    }
    if (method === 'POST' && route.indexOf('/api/v1/partners/') === 0) return ApiResponseValidator.isRecordField(data, 'message');
    if (route === '/api/v1/wrong-book/scanned') return ApiResponseValidator.isRecordField(data, 'item') &&
      ApiResponseValidator.hasString(data['item'] as Record<string, Object>, 'exerciseId');
    if (route === '/api/v1/learning-records') return ApiResponseValidator.hasArray(data, 'records') &&
      (data['nextCursor'] === null || ApiResponseValidator.isString(data, 'nextCursor')) &&
      (data['records'] as Object[]).every((item: Object) => ApiResponseValidator.isRecord(item) &&
        ['recordId', 'goalId', 'chatSessionId', 'status', 'nextAction'].every((key: string) => ApiResponseValidator.hasString(item as Record<string, Object>, key)) &&
        ApiResponseValidator.isString(item as Record<string, Object>, 'updatedAt') &&
        ApiResponseValidator.isLearningContext((item as Record<string, Object>)['learningContext']));
    if (route === '/api/v1/learning-reviews') return ApiResponseValidator.hasString(data, 'reviewId') && ApiResponseValidator.hasString(data, 'summary') &&
      ApiResponseValidator.hasString(data, 'conclusion') && ApiResponseValidator.hasArray(data, 'evidenceSummary') && ApiResponseValidator.hasArray(data, 'sourceFacts') &&
      ApiResponseValidator.hasString(data, 'examMode') && ApiResponseValidator.isString(data, 'fallbackReason') &&
      ApiResponseValidator.hasArray(data, 'actions') && (data['actions'] as Object[]).every((item: Object) => ApiResponseValidator.isReviewAction(item));
    if (route === '/api/v1/learning-review-tasks') return ApiResponseValidator.hasArray(data, 'tasks');
    if (route === '/api/v1/learning-review-tasks/complete') return ApiResponseValidator.hasArray(data, 'tasks');
    if (method === 'POST' && route.indexOf('/api/v1/learning-reviews/') === 0) return ApiResponseValidator.hasArray(data, 'tasks');
    if (method === 'POST' && route === '/api/v1/plans/current/assignments') {
      return ApiResponseValidator.isPlan(data);
    }

    if (method === 'PUT' && route.indexOf('/api/v1/profile/') === 0 && route.endsWith('/preferences')) {
      return ApiResponseValidator.hasNumber(data, 'profileVersion') && ApiResponseValidator.hasArray(data, 'mastery');
    }
    if (method === 'PUT' && route.indexOf('/api/v1/documents/') === 0 && route.endsWith('/knowledge-points')) {
      return ApiResponseValidator.hasString(data, 'documentId') && ApiResponseValidator.hasArray(data, 'knowledgePoints');
    }
    if (method === 'GET' && route.indexOf('/api/v1/exercise-submissions/') === 0) {
      return ApiResponseValidator.hasArray(data, 'review') && ApiResponseValidator.isRecordField(data, 'assessment');
    }
    if (route === '/api/v1/focus-sessions') {
      return ApiResponseValidator.hasString(data, 'userId') && (method === 'GET'
        ? ApiResponseValidator.hasArray(data, 'sessions')
        : ApiResponseValidator.hasString(data, 'eventId') &&
          ApiResponseValidator.hasBoolean(data, 'planTaskMatched'));
    }

    if (method === 'POST' && route === '/api/v1/workflows') {
      return ApiResponseValidator.hasString(data, 'sessionId') &&
        ApiResponseValidator.hasString(data, 'traceId') &&
        ApiResponseValidator.hasString(data, 'status') &&
        ApiResponseValidator.hasString(data, 'currentStep') &&
        ApiResponseValidator.hasString(data, 'nextAction');
    }
    if (route.indexOf('/api/v1/workflows/chat/') === 0 && route.endsWith('/goals')) {
      return method === 'GET' ? ApiResponseValidator.hasArray(data, 'goals') : ApiResponseValidator.hasString(data, 'status');
    }
    if (method === 'GET' && route.indexOf('/api/v1/workflows/chat/') === 0) {
      return ApiResponseValidator.isLearningContext(payload);
    }
    if (method === 'GET' && route.indexOf('/api/v1/workflows/') === 0) {
      return ApiResponseValidator.hasString(data, 'status') &&
        ApiResponseValidator.hasNumber(data, 'stateVersion') &&
        ApiResponseValidator.isNullableString(data, 'currentAgent') &&
        ApiResponseValidator.isNullableString(data, 'finalAction');
    }
    if (method === 'POST' && route.indexOf('/api/v1/workflows/') === 0 && route.endsWith('/run')) {
      return ApiResponseValidator.hasString(data, 'sessionId') &&
        ApiResponseValidator.hasString(data, 'traceId') &&
        ApiResponseValidator.hasString(data, 'status') &&
        ApiResponseValidator.hasString(data, 'currentStep') &&
        ApiResponseValidator.hasString(data, 'currentAgent') &&
        ApiResponseValidator.hasNumber(data, 'stateVersion') &&
        ApiResponseValidator.isNullableString(data, 'finalAction');
    }
    if (method === 'POST' && route.startsWith('/api/v1/profile/') && route.endsWith('/knowledge-points/manual')) {
      return ['knowledgePointId', 'knowledgePointName', 'sourceCourse', 'lastUpdated'].every(
        (key: string) => ApiResponseValidator.hasString(data, key)) &&
        ApiResponseValidator.hasNumber(data, 'masteryScore') && ApiResponseValidator.hasNumber(data, 'confidence');
    }
    if (method === 'POST' && route.indexOf('/api/v1/profile/') === 0 && route.endsWith('/knowledge-points')) {
      return ApiResponseValidator.hasNumber(data, 'profileVersion') &&
        ApiResponseValidator.hasArray(data, 'mastery') &&
        ApiResponseValidator.hasArray(data, 'history') &&
        ApiResponseValidator.hasArray(data, 'evidence') && ApiResponseValidator.validTopics(data);
    }
    if (method === 'GET' && route.indexOf('/api/v1/profile/') === 0) {
      return ApiResponseValidator.hasNumber(data, 'profileVersion') &&
        ApiResponseValidator.hasArray(data, 'mastery') &&
        ApiResponseValidator.hasArray(data, 'history') &&
        ApiResponseValidator.hasArray(data, 'evidence') && ApiResponseValidator.validTopics(data);
    }
    if (method === 'GET' && route === '/api/v1/plans/current') {
      return ApiResponseValidator.isPlan(data);
    }
    if ((method === 'POST' && route === '/api/v1/plans/current/availability') ||
      (method === 'POST' && route === '/api/v1/plans/current/tasks/schedule')) {
      return ApiResponseValidator.isRecordField(data, 'plan') &&
        ApiResponseValidator.isPlan(data['plan'] as Record<string, Object>) &&
        ApiResponseValidator.isRecordField(data, 'planDiff') &&
        ApiResponseValidator.hasBoolean(data, 'changed') && ApiResponseValidator.hasString(data, 'traceId');
    }
    if (method === 'POST' && route === '/api/v1/exercises/photo-practice/generate') {
      return ['calculation', 'written'].includes(data['type'] as string) &&
        ['exerciseId', 'title', 'stem'].every((key: string) => ApiResponseValidator.hasString(data, key));
    }
    if (method === 'POST' && route.startsWith('/api/v1/exercises/photo-practice/') && route.endsWith('/wrong-book')) {
      return ApiResponseValidator.hasString(data, 'exerciseId') && ApiResponseValidator.hasBoolean(data, 'added');
    }
    if (method === 'POST' && route.startsWith('/api/v1/exercises/photo-practice/') &&
      (route.endsWith('/grade') || route.endsWith('/complete'))) {
      if (!ApiResponseValidator.hasString(data, 'exerciseId')) return false;
      if (route.endsWith('/complete') && (!ApiResponseValidator.hasString(data, 'attemptId') ||
        !ApiResponseValidator.hasString(data, 'knowledgePointId') || !ApiResponseValidator.hasString(data, 'knowledgePointName'))) return false;
      if (data['status'] === 'unknown') return route.endsWith('/complete') && ApiResponseValidator.hasString(data, 'explanation');
      if (data['status'] === 'review') return route.endsWith('/grade') && ApiResponseValidator.hasString(data, 'transcript') &&
        ApiResponseValidator.hasString(data, 'attemptId');
      if (data['status'] === 'retake') return ApiResponseValidator.hasString(data, 'message');
      return data['status'] === 'graded' && ApiResponseValidator.hasString(data, 'transcript') &&
        ApiResponseValidator.hasString(data, 'explanation') && ApiResponseValidator.hasNumber(data, 'score') &&
        ApiResponseValidator.hasNumber(data, 'maxScore') && ApiResponseValidator.hasArray(data, 'criteria') &&
        (data['criteria'] as Object[]).every((item: Object) => {
          if (!ApiResponseValidator.isRecord(item)) return false;
          const row = item as Record<string, Object>;
          return ['id', 'label', 'feedback'].every((key: string) => ApiResponseValidator.hasString(row, key)) &&
            ApiResponseValidator.hasNumber(row, 'points') && ApiResponseValidator.hasNumber(row, 'maxPoints');
        });
    }
    if (method === 'GET' && route === '/api/v1/exercises/document-banks') {
      return ApiResponseValidator.hasArray(data, 'banks') && ApiResponseValidator.hasNumber(data, 'maxCount') &&
        (data['banks'] as Object[]).every((item: Object) => ApiResponseValidator.isRecord(item) &&
          ['kbId', 'documentId', 'fileName'].every((key: string) => ApiResponseValidator.hasString(item as Record<string, Object>, key)) &&
          ['count', 'remaining'].every((key: string) => ApiResponseValidator.hasNumber(item as Record<string, Object>, key)));
    }
    if (method === 'GET' && route === '/api/v1/exercises/material-options') {
      return ApiResponseValidator.hasArray(data, 'options') &&
        (data['options'] as Object[]).every((item: Object) => ApiResponseValidator.isRecord(item) &&
          ['kbId', 'documentId', 'fileName'].every((key: string) =>
            ApiResponseValidator.hasString(item as Record<string, Object>, key)));
    }
    if (method === 'GET' && route === '/api/v1/exercises/outline-recommendations') {
      return ApiResponseValidator.hasArray(data, 'points') &&
        (data['status'] === undefined || ['ready', 'no_outline', 'no_priorities', 'outline_topics', 'model_unavailable'].includes(data['status'] as string)) &&
        (data['points'] as Object[]).every((item: Object) => ApiResponseValidator.isRecord(item) &&
          ['knowledgePointId', 'knowledgePointName', 'outlineFileName'].every((key: string) =>
            ApiResponseValidator.hasString(item as Record<string, Object>, key)));
    }
    if (method === 'GET' && route.indexOf('/api/v1/exercises/') === 0 && route.endsWith('/sources')) {
      return ApiResponseValidator.hasString(data, 'exerciseId') && ApiResponseValidator.hasArray(data, 'sources');
    }
    if (method === 'GET' && route.indexOf('/api/v1/exercises/') === 0 && !route.endsWith('/submit')) {
      return ApiResponseValidator.hasString(data, 'setId') && ApiResponseValidator.hasArray(data, 'exercises');
    }
    if (method === 'POST' && route.indexOf('/api/v1/exercises/') === 0 && route.endsWith('/submit')) {
      return ApiResponseValidator.isRecordField(data, 'assessment') &&
        ApiResponseValidator.hasBoolean(data, 'needReplan') &&
        ApiResponseValidator.isNullableRecord(data, 'masteryUpdate') &&
        ApiResponseValidator.hasArray(data, 'review');
    }
    if (method === 'GET' && route === '/api/v1/wrong-book') {
      return ApiResponseValidator.hasString(data, 'userId') &&
        ApiResponseValidator.hasNumber(data, 'total') && ApiResponseValidator.hasArray(data, 'courses');
    }
    if (method === 'POST' && route === '/api/v1/wrong-book/classify') {
      return ApiResponseValidator.hasString(data, 'courseName') && ApiResponseValidator.hasNumber(data, 'updatedCount');
    }
    if (method === 'POST' && route.indexOf('/api/v1/wrong-book/') === 0 && route.endsWith('/attempt')) {
      return ApiResponseValidator.hasString(data, 'exerciseId') &&
        ApiResponseValidator.hasBoolean(data, 'correct') &&
        ApiResponseValidator.hasNumber(data, 'correctCount') &&
        ApiResponseValidator.hasBoolean(data, 'removed');
    }
    if (method === 'POST' && route.indexOf('/api/v1/wrong-book/') === 0) {
      return ApiResponseValidator.hasString(data, 'exerciseId') &&
        ApiResponseValidator.hasBoolean(data, 'added') &&
        ApiResponseValidator.hasBoolean(data, 'removed');
    }
    if (method === 'GET' && route.indexOf('/api/v1/plans/') === 0 && route.endsWith('/diff')) {
      return ApiResponseValidator.hasNumber(data, 'oldVersion') &&
        ApiResponseValidator.hasNumber(data, 'newVersion') &&
        ApiResponseValidator.hasArray(data, 'changedTasks') &&
        ApiResponseValidator.hasString(data, 'adjustmentReason') &&
        ApiResponseValidator.hasArray(data, 'triggerEvidence');
    }
    if (method === 'GET' && route.indexOf('/api/v1/traces/') === 0) {
      return ApiResponseValidator.hasString(data, 'traceId') && ApiResponseValidator.hasArray(data, 'events');
    }
    if (method === 'POST' && route === '/api/v1/demo/reset') {
      return ApiResponseValidator.hasString(data, 'status') &&
        ApiResponseValidator.hasString(data, 'userId') &&
        ApiResponseValidator.hasString(data, 'traceId') &&
        ApiResponseValidator.isNullableRecord(data, 'profile') &&
        ApiResponseValidator.isNullableRecord(data, 'plan');
    }
    if (method === 'POST' && route === '/api/v1/import/schedule-image') {
      return ApiResponseValidator.hasArray(data, 'courses') &&
        ApiResponseValidator.hasNumber(data, 'recognizedCount') &&
        ApiResponseValidator.hasString(data, 'model') &&
        ApiResponseValidator.hasString(data, 'recognizedAt');
    }
    if (method === 'POST' && route === '/api/v1/agent/partner-match') {
      return ApiResponseValidator.hasString(data, 'userId') &&
        ApiResponseValidator.hasArray(data, 'candidates') &&
        ApiResponseValidator.hasBoolean(data, 'realModeUnavailable');
    }
    if (method === 'POST' && route === '/api/v1/agent/partner-invitations') {
      return ApiResponseValidator.isRecordField(data, 'invitation');
    }
    if (method === 'GET' && route === '/api/v1/agent/partner-invitations') {
      return ApiResponseValidator.hasString(data, 'box') &&
        ApiResponseValidator.hasString(data, 'userId') &&
        ApiResponseValidator.hasArray(data, 'invitations') &&
        ApiResponseValidator.hasNumber(data, 'pendingCount');
    }
    if (method === 'POST' && route.indexOf('/api/v1/agent/partner-invitations/') === 0) {
      return ApiResponseValidator.isRecordField(data, 'invitation');
    }
    if (method === 'GET' && route === '/api/v1/agent/partner-contacts') {
      return ApiResponseValidator.hasString(data, 'userId') &&
        ApiResponseValidator.hasArray(data, 'contacts');
    }
    if (method === 'POST' && route === '/api/v1/agent/proactive') {
      return ApiResponseValidator.hasBoolean(data, 'shouldNotify') &&
        ApiResponseValidator.hasString(data, 'channel') &&
        ApiResponseValidator.isString(data, 'title') &&
        ApiResponseValidator.isString(data, 'body') &&
        ApiResponseValidator.isRecordField(data, 'action') &&
        ApiResponseValidator.hasArray(data, 'contextTags') &&
        ApiResponseValidator.hasString(data, 'reason') &&
        ApiResponseValidator.hasArray(data, 'factors') &&
        ApiResponseValidator.isRecordField(data, 'cardData');
    }
    if (method === 'GET' && route.indexOf('/api/v1/knowledge-bases') === 0) {
      if (route.indexOf('/documents') > 0) {
        return ApiResponseValidator.hasString(data, 'kbId') &&
          ApiResponseValidator.hasArray(data, 'documents');
      }
      if (route === '/api/v1/knowledge-bases') {
        return ApiResponseValidator.hasArray(data, 'knowledgeBases') &&
          ApiResponseValidator.hasNumber(data, 'total');
      }
      return ApiResponseValidator.hasString(data, 'kbId') &&
        ApiResponseValidator.hasString(data, 'name') &&
        ApiResponseValidator.hasString(data, 'courseName');
    }
    if (method === 'POST' && route === '/api/v1/knowledge-bases') {
      return ApiResponseValidator.hasString(data, 'kbId') &&
        ApiResponseValidator.hasString(data, 'name');
    }
    if (method === 'DELETE' && route.indexOf('/api/v1/knowledge-bases/') === 0) {
      return ApiResponseValidator.hasString(data, 'status');
    }
    if (method === 'POST' && route.indexOf('/api/v1/knowledge-bases/') === 0
      && route.endsWith('/documents')) {
      return ApiResponseValidator.hasString(data, 'documentId') &&
        ApiResponseValidator.hasString(data, 'status') &&
        ApiResponseValidator.hasString(data, 'fileName');
    }
    if (method === 'GET' && route.indexOf('/api/v1/documents/') === 0) {
      return ApiResponseValidator.hasString(data, 'documentId') &&
        ApiResponseValidator.hasString(data, 'fileName') &&
        ApiResponseValidator.hasArray(data, 'chunks') &&
        ApiResponseValidator.hasNumber(data, 'chunkTotal') &&
        ApiResponseValidator.hasBoolean(data, 'chunksTruncated');
    }
    if (method === 'DELETE' && route.indexOf('/api/v1/documents/') === 0) {
      return ApiResponseValidator.hasString(data, 'status');
    }
    if (method === 'POST' && route.indexOf('/api/v1/knowledge-bases/') === 0
      && route.endsWith('/search')) {
      return ApiResponseValidator.hasString(data, 'kbId') &&
        ApiResponseValidator.hasString(data, 'query') &&
        ApiResponseValidator.hasArray(data, 'hits') &&
        ApiResponseValidator.hasNumber(data, 'totalScanned') &&
        ApiResponseValidator.hasString(data, 'retrievalMode') &&
        ApiResponseValidator.hasBoolean(data, 'semanticAvailable') &&
        ApiResponseValidator.hasNumber(data, 'semanticWeight');
    }
    if (method === 'POST' && route === '/api/v1/auth/register') {
      return ApiResponseValidator.isAuthSession(data);
    }
    if (method === 'POST' && route === '/api/v1/auth/select-account') {
      return ApiResponseValidator.isAuthSession(data);
    }
    if (method === 'POST' && route === '/api/v1/auth/login') {
      return ApiResponseValidator.isAuthSession(data);
    }
    if (method === 'POST' && route === '/api/v1/auth/login-or-register') {
      return ApiResponseValidator.isAuthSession(data);
    }
    if (method === 'POST' && route === '/api/v1/auth/login-with-huawei') {
      return ApiResponseValidator.isAuthSession(data);
    }
    if (method === 'POST' && route === '/api/v1/auth/send-code') {
      return ApiResponseValidator.isPhoneCodeSendResponse(data);
    }
    if (method === 'POST' && route === '/api/v1/auth/verify-code') {
      return ApiResponseValidator.isAuthSession(data);
    }
    if (method === 'POST' && route === '/api/v1/auth/change-password') {
      return ApiResponseValidator.hasString(data, 'status');
    }
    if (method === 'POST' && route === '/api/v1/auth/logout') {
      return ApiResponseValidator.hasString(data, 'status');
    }
    if ((method === 'GET' || method === 'PUT') && route === '/api/v1/auth/me') {
      return ApiResponseValidator.isAuthUserField(data, 'user');
    }
    if (method === 'DELETE' && route === '/api/v1/auth/account') {
      return ApiResponseValidator.hasString(data, 'status');
    }
    return false;
  }

  static isLearningContext(payload: Object): boolean {
    if (!ApiResponseValidator.isRecord(payload)) return false;
    const row: Record<string, Object> = payload as Record<string, Object>;
    const strings: string[] = ['goalId', 'sessionId', 'traceId', 'assessmentTraceId', 'goal', 'status',
      'currentAgent', 'waitingFor', 'nextAction', 'decisionSource', 'knowledgePointId',
      'knowledgePointName', 'planId', 'sourceMode', 'kbId', 'assessmentStatus'];
    for (let index: number = 0; index < strings.length; index++) {
      if (!ApiResponseValidator.isString(row, strings[index])) return false;
    }
    if (!ApiResponseValidator.hasString(row, 'goalId') || row['goalId'] !== row['sessionId'] || !ApiResponseValidator.hasNumber(row, 'stateVersion') ||
      !ApiResponseValidator.hasNumber(row, 'assessedQuestionCount') ||
      !ApiResponseValidator.isRecordField(row, 'action') || !ApiResponseValidator.hasArray(row, 'handoffs')) return false;
    const action: Record<string, Object> = row['action'] as Record<string, Object>;
    if (!ApiResponseValidator.hasString(action, 'label') || !ApiResponseValidator.isString(action, 'targetPage')) return false;
    const tasks: Object[] = row['handoffs'] as Object[];
    for (let index: number = 0; index < tasks.length; index++) {
      if (!ApiResponseValidator.isRecord(tasks[index])) return false;
      const task: Record<string, Object> = tasks[index] as Record<string, Object>;
      if (!ApiResponseValidator.hasString(task, 'agentTaskId') || !ApiResponseValidator.hasString(task, 'sender') ||
        !ApiResponseValidator.hasString(task, 'receiver') || !ApiResponseValidator.hasString(task, 'status') ||
        !ApiResponseValidator.hasArray(task, 'toolCalls')) return false;
    }
    return true;
  }

  private static isAuthSession(data: Record<string, Object>): boolean {
    if (ApiResponseValidator.hasString(data, 'selectionToken') && ApiResponseValidator.hasArray(data, 'accounts')) {
      const accounts: Object[] = data['accounts'] as Object[];
      return accounts.length > 1 && accounts.every((item: Object): boolean => {
        if (!ApiResponseValidator.isRecord(item)) return false;
        const user: Record<string, Object> = item as Record<string, Object>;
        return ApiResponseValidator.hasString(user, 'userId') && ApiResponseValidator.hasString(user, 'nickname') &&
          ApiResponseValidator.isString(user, 'grade') && ApiResponseValidator.isString(user, 'createdAt') &&
          ApiResponseValidator.isString(user, 'avatar');
      });
    }
    return ApiResponseValidator.isAuthUserField(data, 'user') &&
      ApiResponseValidator.hasString(data, 'token') &&
      ApiResponseValidator.hasString(data, 'expiresAt') &&
      (data['needsPasswordSetup'] === undefined || typeof data['needsPasswordSetup'] === 'boolean');
  }

  private static isPhoneCodeSendResponse(data: Record<string, Object>): boolean {
    return ApiResponseValidator.hasString(data, 'phoneMasked') &&
      ApiResponseValidator.hasNumber(data, 'expiresInSeconds') &&
      ApiResponseValidator.hasNumber(data, 'resendAfterSeconds') &&
      ApiResponseValidator.hasBoolean(data, 'smsDelivered');
  }

  private static isAuthUserField(data: Record<string, Object>, key: string): boolean {
    if (!ApiResponseValidator.isRecordField(data, key)) {
      return false;
    }
    const user: Record<string, Object> = data[key] as Record<string, Object>;
    return ApiResponseValidator.hasString(user, 'userId') &&
      ApiResponseValidator.hasString(user, 'nickname') &&
      (user['needsPasswordSetup'] === undefined || typeof user['needsPasswordSetup'] === 'boolean');
  }

  private static validBudget(payload: Object): boolean {
    if (!ApiResponseValidator.isRecord(payload)) return false;
    const data: Record<string, Object> = payload as Record<string, Object>;
    return ['availableMinutes','scheduledMinutes','unallocatedMinutes','unscheduledMinutes'].every((key: string) => ApiResponseValidator.hasNumber(data, key)) &&
      (data['allocationMode'] === undefined || ['under_budget','exact_budget','surplus_model','surplus_fallback'].includes(data['allocationMode'] as string)) &&
      (data['baseTotalMinutes'] === undefined || ApiResponseValidator.hasNumber(data, 'baseTotalMinutes')) &&
      (data['allocationReason'] === undefined || ApiResponseValidator.isString(data, 'allocationReason'));
  }
  private static validTopics(data: Record<string, Object>): boolean {
    if (!ApiResponseValidator.isRecordField(data, 'profile')) return true;
    const profile: Record<string, Object> = data['profile'] as Record<string, Object>;
    if (profile['topicGroups'] === undefined) return true;
    return ApiResponseValidator.hasArray(profile, 'topicGroups') && (profile['topicGroups'] as Object[]).every((value: Object) => {
      if (!ApiResponseValidator.isRecord(value)) return false;
      const group: Record<string, Object> = value as Record<string, Object>;
      return ['topicGroupId','topicGroupName','sourceCourse'].every((key: string) => ApiResponseValidator.hasString(group, key)) &&
        ['memberCount','evidenceQuestionCount'].every((key: string) => ApiResponseValidator.hasNumber(group, key)) &&
        (group['masteryScore'] === null || ApiResponseValidator.hasNumber(group, 'masteryScore')) &&
        (group['recentAccuracy'] === null || ApiResponseValidator.hasNumber(group, 'recentAccuracy')) &&
        ApiResponseValidator.hasArray(group, 'memberPointIds') && (group['memberPointIds'] as Object[]).every((id: Object) => typeof id === 'string') &&
        ApiResponseValidator.hasArray(group, 'memberPoints') &&
        (group['memberPoints'] as Object[]).every((member: Object) => ApiResponseValidator.isRecord(member) &&
          ['knowledgePointId','name'].every((key: string) => ApiResponseValidator.hasString(member as Record<string, Object>, key)) &&
          ApiResponseValidator.hasNumber(member as Record<string, Object>, 'evidenceQuestionCount') &&
          ((member as Record<string, Object>)['masteryScore'] === null || ApiResponseValidator.hasNumber(member as Record<string, Object>, 'masteryScore')));
    });
  }
  private static isReviewAction(payload: Object): boolean {
    if (!ApiResponseValidator.isRecord(payload)) return false;
    const item: Record<string, Object> = payload as Record<string, Object>;
    return ['actionId','title','why','doneWhen','priority','targetPage'].every((key: string) => ApiResponseValidator.hasString(item, key)) &&
      ApiResponseValidator.isString(item, 'knowledgePointId') && ApiResponseValidator.hasNumber(item, 'durationMinutes') &&
      Number.isInteger(item['durationMinutes'] as number) && (item['durationMinutes'] as number) >= 15 && (item['durationMinutes'] as number) <= 60 && (item['durationMinutes'] as number) % 5 === 0 &&
      ['pages/ExercisePractice','pages/StudyPlan','pages/LearningSetup'].includes(item['targetPage'] as string) &&
      ApiResponseValidator.hasArray(item, 'steps') && (item['steps'] as Object[]).length > 0 && (item['steps'] as Object[]).length <= 3 &&
      (item['steps'] as Object[]).every((step: Object) => typeof step === 'string' && (step as string).length > 0);
  }
  private static isPlan(data: Record<string, Object>): boolean {
    return ApiResponseValidator.isNullableString(data, 'planId') &&
      ApiResponseValidator.hasNumber(data, 'version') &&
      ApiResponseValidator.hasNumber(data, 'generatedFromProfileVersion') &&
      ApiResponseValidator.hasArray(data, 'tasks') && (data['tasks'] as Object[]).every((task: Object) => ApiResponseValidator.isPlanTask(task)) &&
      (data['unscheduledTasks'] === undefined || (ApiResponseValidator.hasArray(data, 'unscheduledTasks') &&
        (data['unscheduledTasks'] as Object[]).every((task: Object) => ApiResponseValidator.isPlanTask(task)))) &&
      (data['budgetSummary'] === undefined || ApiResponseValidator.validBudget(data['budgetSummary']));
  }

  private static isPlanTask(payload: Object): boolean {
    if (!ApiResponseValidator.isRecord(payload)) return false;
    const task: Record<string, Object> = payload as Record<string, Object>;
    return ['taskId', 'knowledgePointId', 'knowledgePointName', 'status'].every((key: string) => ApiResponseValidator.hasString(task, key)) &&
      ApiResponseValidator.hasNumber(task, 'durationMinutes') &&
      ['dueAt','scheduledDate','allocationReason'].every((key: string) => task[key] === undefined || ApiResponseValidator.isString(task, key)) &&
      (task['baseDurationMinutes'] === undefined || (ApiResponseValidator.hasNumber(task, 'baseDurationMinutes') && (task['baseDurationMinutes'] as number) > 0)) &&
      (task['extraMinutes'] === undefined || (ApiResponseValidator.hasNumber(task, 'extraMinutes') && Number.isInteger(task['extraMinutes'] as number) &&
        (task['extraMinutes'] as number) >= 0 && (task['extraMinutes'] as number) <= 60 && (task['extraMinutes'] as number) % 5 === 0));
  }

  private static hasString(data: Record<string, Object>, key: string): boolean {
    const value: Object | undefined = data[key] as Object | undefined;
    return typeof value === 'string' && (value as string).trim().length > 0;
  }

  private static isString(data: Record<string, Object>, key: string): boolean {
    return typeof data[key] === 'string';
  }

  private static hasNumber(data: Record<string, Object>, key: string): boolean {
    return typeof data[key] === 'number';
  }

  private static hasBoolean(data: Record<string, Object>, key: string): boolean {
    return typeof data[key] === 'boolean';
  }

  private static hasArray(data: Record<string, Object>, key: string): boolean {
    return Array.isArray(data[key]);
  }

  private static isRecordField(data: Record<string, Object>, key: string): boolean {
    const value: Object | undefined = data[key] as Object | undefined;
    return value !== undefined && ApiResponseValidator.isRecord(value);
  }

  private static isNullableRecord(data: Record<string, Object>, key: string): boolean {
    const value: Object | undefined = data[key] as Object | undefined;
    return value === null || (value !== undefined && ApiResponseValidator.isRecord(value));
  }

  private static isNullableString(data: Record<string, Object>, key: string): boolean {
    const value: Object | undefined = data[key] as Object | undefined;
    return value === null || typeof value === 'string';
  }

  private static isRecord(value: Object): boolean {
    return typeof value === 'object' && value !== null && !Array.isArray(value);
  }
}
