"""Private original files with checksums, bounded reads and short-lived downloads."""
from datetime import datetime, timezone
import hashlib
import os
from pathlib import Path
import uuid

MAX_BYTES = 8 * 1024 * 1024


class FileStorage:
    def __init__(self):
        self.backend = os.getenv("FILE_STORAGE", "local")
        self.bucket = os.getenv("S3_BUCKET", "")
        if self.backend == "s3":
            import boto3
            from botocore.config import Config
            self.client = boto3.client("s3", endpoint_url=os.environ["S3_ENDPOINT_URL"],
                region_name=os.getenv("S3_REGION", "us-east-1"),
                aws_access_key_id=os.environ["S3_ACCESS_KEY_ID"],
                aws_secret_access_key=os.environ["S3_SECRET_ACCESS_KEY"],
                config=Config(signature_version="s3v4", connect_timeout=5, read_timeout=30,
                              retries={"max_attempts": 2}, s3={"addressing_style": "path"}))
        elif self.backend == "obs":
            from obs import ObsClient
            import certifi
            self.client = ObsClient(access_key_id=os.environ["S3_ACCESS_KEY_ID"],
                secret_access_key=os.environ["S3_SECRET_ACCESS_KEY"], server=os.environ["S3_ENDPOINT_URL"],
                ssl_verify=os.getenv("S3_CA_BUNDLE") or certifi.where(), timeout=30,
                use_http_conns=True)
        elif self.backend != "local":
            raise ValueError("FILE_STORAGE must be local, obs or s3")
        self.root = Path(os.getenv("FILE_STORAGE_DIR", "data/files")).resolve()

    def _path(self, key):
        path = (self.root / key).resolve()
        if not path.is_relative_to(self.root):
            raise ValueError("invalid object key")
        # ZIPs may be extracted under a long Windows directory. Validate the
        # resolved path first, then use the native extended-length spelling for IO.
        if os.name == 'nt' and not str(path).startswith('\\\\?\\'):
            value = str(path)
            path = Path('\\\\?\\UNC\\' + value[2:] if value.startswith('\\\\') else '\\\\?\\' + value)
        return path

    def put(self, owner, raw, file_name):
        if not raw or len(raw) > MAX_BYTES:
            raise ValueError("empty or oversized file")
        file_id = "file-" + uuid.uuid4().hex
        key = f"originals/{uuid.uuid4().hex}/{file_id}"
        record = {"fileId": file_id, "userId": owner, "objectKey": key,
                  "backend": self.backend, "bucket": self.bucket, "fileName": file_name,
                  "sizeBytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest(),
                  "status": "uploaded", "createdAt": datetime.now(timezone.utc).isoformat()}
        if self.backend == "s3":
            self.client.put_object(Bucket=self.bucket, Key=key, Body=raw, ACL="private",
                                   ContentType="application/octet-stream")
        elif self.backend == "obs":
            from obs import PutObjectHeader
            response = self.client.putContent(self.bucket, key, raw,
                headers=PutObjectHeader(acl="private", contentType="application/octet-stream"))
            if response.status >= 300:
                raise RuntimeError("object_upload_failed")
        else:
            path = self._path(key)
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(raw)
        return record

    def read(self, record):
        key = record["objectKey"]
        if self.backend == "s3":
            response = self.client.get_object(Bucket=record["bucket"], Key=key)
            body = response["Body"]
            try:
                raw = body.read(MAX_BYTES + 1)
            finally:
                body.close()
        elif self.backend == "obs":
            response = self.client.getObject(record["bucket"], key, loadStreamInMemory=False)
            if response.status >= 300:
                raise RuntimeError("object_download_failed")
            stream = response.body.response
            try:
                raw = stream.read(MAX_BYTES + 1)
            finally:
                stream.close()
        else:
            with self._path(key).open("rb") as stream:
                raw = stream.read(MAX_BYTES + 1)
        if len(raw) > MAX_BYTES or hashlib.sha256(raw).hexdigest() != record["sha256"]:
            raise ValueError("file checksum mismatch")
        return raw

    def delete(self, record):
        if self.backend == "s3":
            self.client.delete_object(Bucket=record["bucket"], Key=record["objectKey"])
        elif self.backend == "obs":
            response = self.client.deleteObject(record["bucket"], record["objectKey"])
            if response.status >= 300 and response.status != 404:
                raise RuntimeError("object_delete_failed")
        else:
            self._path(record["objectKey"]).unlink(missing_ok=True)

    def download_url(self, record):
        if self.backend == "s3":
            return self.client.generate_presigned_url("get_object",
                Params={"Bucket": record["bucket"], "Key": record["objectKey"],
                        "ResponseContentDisposition": "attachment"}, ExpiresIn=120)
        if self.backend == "obs":
            return self.client.createSignedUrl(method="GET", bucketName=record["bucket"],
                objectKey=record["objectKey"], expires=120,
                queryParams={"response-content-disposition": "attachment"}).signedUrl
        return None


def storage():
    return FileStorage()


def schedule_delete(repository, file_record):
    from app.services.job_queue import enqueue
    enqueue(repository, "delete_file", file_record["userId"], {"file": file_record}, file_record["fileId"])
