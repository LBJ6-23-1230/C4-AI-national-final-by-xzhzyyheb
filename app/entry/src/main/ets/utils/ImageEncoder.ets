import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { image } from '@kit.ImageKit';

export class ImageEncoder {
  private static readonly MAX_BYTES: number = 4 * 1024 * 1024;

  static async toBase64(uri: string): Promise<string> {
    const target: string = (uri ?? '').trim();
    if (target.length === 0) {
      return '';
    }
    let file: fileIo.File | null = null;
    try {
      file = await fileIo.open(target, fileIo.OpenMode.READ_ONLY);
      const stat: fileIo.Stat = await fileIo.stat(file.fd);
      const size: number = stat.size;
      if (size <= 0 || size > ImageEncoder.MAX_BYTES) {
        return '';
      }
      const buffer: ArrayBuffer = new ArrayBuffer(size);
      const read: number = await fileIo.read(file.fd, buffer);
      if (read !== size) {
        return '';
      }
      const bytes: Uint8Array = read === size
        ? new Uint8Array(buffer)
        : new Uint8Array(buffer.slice(0, read));
      const helper: util.Base64Helper = new util.Base64Helper();
      return await helper.encodeToString(bytes);
    } catch (error) {
      return '';
    } finally {
      if (file !== null) {
        try {
          await fileIo.close(file);
        } catch (closeError) {
        }
      }
    }
  }

  static describeFailure(): string {
    return '图片读取失败或超过 4MB 上限，请换一张重试。';
  }

  static async encodePracticePhoto(uri: string): Promise<string> {
    let file: fileIo.File | null = null;
    let source: image.ImageSource | null = null;
    let pixels: image.PixelMap | null = null;
    let packer: image.ImagePacker | null = null;
    try {
      file = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
      if ((await fileIo.stat(file.fd)).size > 25 * 1024 * 1024) return '';
      source = image.createImageSource(file.fd);
      const info: image.ImageInfo = await source.getImageInfo();
      if (info.size.width <= 0 || info.size.height <= 0) return '';
      const ratio: number = Math.min(1, 1600 / Math.max(info.size.width, info.size.height));
      pixels = await source.createPixelMap({ desiredSize: {
        width: Math.max(1, Math.round(info.size.width * ratio)),
        height: Math.max(1, Math.round(info.size.height * ratio))
      } });
      packer = image.createImagePacker();
      const packed: ArrayBuffer = await packer.packing(pixels, { format: 'image/jpeg', quality: 85 });
      if (packed.byteLength > 1536 * 1024) return '';
      return await new util.Base64Helper().encodeToString(new Uint8Array(packed));
    } catch (error) {
      return '';
    } finally {
      try { if (packer !== null) await packer.release(); } catch (error) {                           }
      try { if (pixels !== null) await pixels.release(); } catch (error) {                           }
      try { if (source !== null) await source.release(); } catch (error) {                           }
      try { if (file !== null) await fileIo.close(file); } catch (error) {                       }
    }
  }

  static fromResource(context: common.Context, mediaId: number): string {
    try {
      const bytes: Uint8Array = context.resourceManager.getMediaContentSync(mediaId);
      if (bytes === undefined || bytes.length === 0 || bytes.length > ImageEncoder.MAX_BYTES) {
        return '';
      }
      const helper: util.Base64Helper = new util.Base64Helper();
      return helper.encodeToStringSync(bytes);
    } catch (error) {
      return '';
    }
  }
}
