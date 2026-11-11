import { asset } from '@kit.AssetStoreKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'TokenCipher';

export class TokenCipher {
  private static readonly ALIAS: string = 'zhixue_mate_session_token_key';
  private static readonly NONCE_BYTES: number = 12;
  private static readonly TAG_BYTES: number = 16;
  private static readonly KEY_BYTES: number = 32;
  private static readonly KEY_ALG: string = 'AES256';
  private static readonly TRANSFORMATION: string = 'AES256|GCM|NoPadding';
  private static readonly AAD_TEXT: string = 'zhixue-mate-token-v1';

  private static key: cryptoFramework.SymKey | null = null;
  private static ready: boolean = false;
  private static unavailableReason: string = '';

  static isReady(): boolean {
    return TokenCipher.ready;
  }

  static reason(): string {
    return TokenCipher.unavailableReason;
  }

  static looksEncrypted(value: string): boolean {
    if (value.length === 0) {
      return false;
    }
    const parts: string[] = value.split('.');
    if (parts.length !== 3) {
      return false;
    }
    const base64: RegExp = /^[A-Za-z0-9+/]+={0,2}$/;
    for (let index: number = 0; index < parts.length; index++) {
      if (!base64.test(parts[index])) {
        return false;
      }
    }
    return true;
  }

  static async initialize(): Promise<boolean> {
    if (TokenCipher.ready) {
      return true;
    }
    try {
      const existing: Uint8Array | null = await TokenCipher.loadKeyBytes();
      if (existing !== null && existing.length === TokenCipher.KEY_BYTES) {
        TokenCipher.key = TokenCipher.importKey(existing);
      } else {
        const generator: cryptoFramework.SymKeyGenerator =
          cryptoFramework.createSymKeyGenerator(TokenCipher.KEY_ALG);
        const generated: cryptoFramework.SymKey = await generator.generateSymKey();
        TokenCipher.key = generated;
        await TokenCipher.storeKeyBytes(generated.getEncoded().data);
      }
      TokenCipher.ready = TokenCipher.key !== null;
      TokenCipher.unavailableReason = TokenCipher.ready ? '' : 'key_unavailable';
      return TokenCipher.ready;
    } catch (error) {
      const typed = error as BusinessErrorLike;
      hilog.warn(DOMAIN, TAG, '%{public}s',
        `TokenCipher init failed: ${typed.code} ${typed.message}`);
      TokenCipher.key = null;
      TokenCipher.ready = false;
      TokenCipher.unavailableReason = `crypto_init_failed:${typed.code}`;
      return false;
    }
  }

  static encrypt(plain: string): string | null {
    const key: cryptoFramework.SymKey | null = TokenCipher.key;
    if (key === null || plain.length === 0) {
      return null;
    }
    try {
      const cipher: cryptoFramework.Cipher =
        cryptoFramework.createCipher(TokenCipher.TRANSFORMATION);
      const nonce: Uint8Array = TokenCipher.randomBytes(TokenCipher.NONCE_BYTES);
      const spec: cryptoFramework.GcmParamsSpec = {
        algName: 'GcmParamsSpec',
        iv: { data: nonce },
        aad: { data: TokenCipher.aad() },
        authTag: { data: new Uint8Array(TokenCipher.TAG_BYTES) }
      };
      cipher.initSync(cryptoFramework.CryptoMode.ENCRYPT_MODE, key, spec);
      const payload: Uint8Array =
        cipher.doFinalSync({ data: new util.TextEncoder().encodeInto(plain) }).data;
      if (payload.length < TokenCipher.TAG_BYTES) {
        return null;
      }
      const tagStart: number = payload.length - TokenCipher.TAG_BYTES;
      const cipherText: Uint8Array = payload.slice(0, tagStart);
      const authTag: Uint8Array = payload.slice(tagStart);
      return `${TokenCipher.toBase64(nonce)}.${TokenCipher.toBase64(cipherText)}.${TokenCipher.toBase64(authTag)}`;
    } catch (error) {
      const typed = error as BusinessErrorLike;
      hilog.warn(DOMAIN, TAG, '%{public}s', `encrypt failed: ${typed.code} ${typed.message}`);
      return null;
    }
  }

  static decrypt(encoded: string): string | null {
    const key: cryptoFramework.SymKey | null = TokenCipher.key;
    if (key === null || encoded.length === 0) {
      return null;
    }
    const parts: string[] = encoded.split('.');
    if (parts.length !== 3) {
      return null;
    }
    try {
      const nonce: Uint8Array = TokenCipher.fromBase64(parts[0]);
      const cipherText: Uint8Array = TokenCipher.fromBase64(parts[1]);
      const authTag: Uint8Array = TokenCipher.fromBase64(parts[2]);
      if (authTag.length !== TokenCipher.TAG_BYTES || nonce.length === 0) {
        return null;
      }
      const cipher: cryptoFramework.Cipher =
        cryptoFramework.createCipher(TokenCipher.TRANSFORMATION);
      const spec: cryptoFramework.GcmParamsSpec = {
        algName: 'GcmParamsSpec',
        iv: { data: nonce },
        aad: { data: TokenCipher.aad() },
        authTag: { data: authTag }
      };
      cipher.initSync(cryptoFramework.CryptoMode.DECRYPT_MODE, key, spec);
      const decrypted: Uint8Array =
        cipher.doFinalSync({ data: cipherText }).data;
      return new util.TextDecoder().decodeToString(decrypted);
    } catch (error) {
      return null;
    }
  }

  private static aad(): Uint8Array {
    return new util.TextEncoder().encodeInto(TokenCipher.AAD_TEXT);
  }

  private static randomBytes(length: number): Uint8Array {
    const random: cryptoFramework.Random = cryptoFramework.createRandom();
    return random.generateRandomSync(length).data;
  }

  private static toBase64(bytes: Uint8Array): string {
    const helper: util.Base64Helper = new util.Base64Helper();
    return helper.encodeToStringSync(bytes);
  }

  private static fromBase64(text: string): Uint8Array {
    const helper: util.Base64Helper = new util.Base64Helper();
    return helper.decodeSync(text);
  }

  private static importKey(raw: Uint8Array): cryptoFramework.SymKey {
    const generator: cryptoFramework.SymKeyGenerator =
      cryptoFramework.createSymKeyGenerator(TokenCipher.KEY_ALG);
    return generator.convertKeySync({ data: raw });
  }

  private static async loadKeyBytes(): Promise<Uint8Array | null> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, TokenCipher.stringToUint8(TokenCipher.ALIAS));
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    let results: Array<asset.AssetMap>;
    try {
      results = await asset.query(query);
    } catch (error) {
      const typed = error as BusinessErrorLike;
      if (typed.code === 24000002) {
        return null;
      }
      throw error as Error;
    }
    if (results.length === 0) {
      return null;
    }
    const secret: Uint8Array | undefined =
      results[0].get(asset.Tag.SECRET) as Uint8Array | undefined;
    return secret !== undefined && secret.length > 0 ? secret : null;
  }

  private static async storeKeyBytes(raw: Uint8Array): Promise<void> {
    const attributes: asset.AssetMap = new Map();
    attributes.set(asset.Tag.ALIAS, TokenCipher.stringToUint8(TokenCipher.ALIAS));
    attributes.set(asset.Tag.SECRET, raw);
    attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    attributes.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.OVERWRITE);
    await asset.add(attributes);
  }

  private static stringToUint8(text: string): Uint8Array {
    return new util.TextEncoder().encodeInto(text);
  }
}

interface BusinessErrorLike {
  code: number;
  message: string;
}
