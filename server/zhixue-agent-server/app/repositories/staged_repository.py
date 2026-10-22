"""Collect one business operation's writes and publish them in one batch."""

from copy import deepcopy

from app.repositories.repository import Repository


class StagedRepository(Repository):
    """Read-your-writes overlay; caller serializes business decisions with its lock.

    This provides crash-atomic publication through the backing apply_batch,
    not cross-process isolation of the earlier reads.
    """

    def __init__(self, repository: Repository):
        self.repository = repository
        self._saves = {}
        self._deletes = set()
        self._committed = False

    def get(self, collection, item_id):
        key = (collection, item_id)
        if key in self._deletes:
            return None
        value = self._saves.get(key) if key in self._saves else self.repository.get(collection, item_id)
        return deepcopy(value)

    def save(self, collection, item_id, value):
        if self._committed:
            raise RuntimeError("operation has already committed")
        key = (collection, item_id)
        self._deletes.discard(key)
        self._saves[key] = deepcopy(value)

    def ids(self, collection):
        keys = dict.fromkeys(self.repository.ids(collection))
        for name, item_id in self._deletes:
            if name == collection:
                keys.pop(item_id, None)
        for name, item_id in self._saves:
            if name == collection:
                keys[item_id] = None
        return list(keys)

    def list(self, collection):
        return [self.get(collection, item_id) for item_id in self.ids(collection)]

    def delete(self, collection, item_id):
        if self._committed:
            raise RuntimeError("operation has already committed")
        key = (collection, item_id)
        self._saves.pop(key, None)
        self._deletes.add(key)

    def apply_batch(self, deletes, saves):
        for collection, item_id in deletes:
            self.delete(collection, item_id)
        for collection, item_id, value in saves:
            self.save(collection, item_id, value)

    def commit(self):
        if self._committed:
            raise RuntimeError("operation has already committed")
        self.repository.apply_batch(list(self._deletes), [
            (collection, item_id, value) for (collection, item_id), value in self._saves.items()])
        self._committed = True
