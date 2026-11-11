"""Stable per-room message ordering with compatible opaque message IDs."""


def message_order(message):
    return message.get('_sequence', 0), message['messageId']


def cursor_order(repository, room, message_id):
    message = repository.get('partner_messages', message_id) if message_id else None
    if message and message.get('roomId') == room:
        return message_order(message)
    return 0, message_id


def save_message(repository, message, retry_key=None):
    """Allocate the sequence inside the caller's write transaction."""
    room = message['roomId']
    counter = repository.get('partner_message_sequences', room) or {}
    sequence = counter.get('lastSequence', 0) + 1
    message['_sequence'] = sequence
    saves = [
        ('partner_message_sequences', room, {'lastSequence': sequence}),
        ('partner_messages', message['messageId'], message),
    ]
    if retry_key is not None:
        saves.append(('partner_message_keys', retry_key, message))
    repository.apply_batch([], saves)


def public_message(message):
    return {key: value for key, value in message.items() if key != '_sequence'}
