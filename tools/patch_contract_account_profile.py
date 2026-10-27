"""Declare account display-profile editing and synchronize the frontend contract."""
import copy
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
canonical = root / "contracts/openapi.json"
doc = json.loads(canonical.read_text(encoding="utf-8"))
schemas = doc["components"]["schemas"]
avatar = {"type": "string", "maxLength": 180000,
          "description": "空串表示默认头像；否则为 JPEG/PNG data URI，解码后不超过128KiB，正方形且边长不超过512px。"}
schemas["AuthUser"]["properties"]["avatar"] = avatar
schemas["AuthProfileUpdateRequest"] = {
    "type": "object", "minProperties": 1, "additionalProperties": False,
    "properties": {"nickname": {"type": "string", "minLength": 1, "maxLength": 16}, "avatar": avatar}}
operation = copy.deepcopy(doc["paths"]["/api/v1/auth/me"]["get"])
operation.update(summary="修改当前账号的昵称与头像", operationId="authUpdateProfile",
                 requestBody={"required": True, "content": {"application/json": {
                     "schema": {"$ref": "#/components/schemas/AuthProfileUpdateRequest"}}}})
operation["responses"]["400"] = {"description": "昵称或头像无效", "content": {"application/json": {
    "schema": {"$ref": "#/components/schemas/ErrorResponse"}}}}
doc["paths"]["/api/v1/auth/me"]["put"] = operation
if "PartnerCandidateProfile" in schemas:
    schemas["PartnerCandidateProfile"]["properties"]["avatar"] = avatar
schemas["PartnerRankedCandidate"]["properties"]["candidate"]["properties"]["avatar"] = avatar
text = json.dumps(doc, ensure_ascii=False, indent=2) + "\n"
canonical.write_text(text, encoding="utf-8")
(root / "app/contracts/openapi.json").write_text(text, encoding="utf-8")
