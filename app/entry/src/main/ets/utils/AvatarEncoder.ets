import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { AvatarCropRect } from './AvatarCropGeometry';

/** Persist image bytes rather than the picker's temporary URI. */
export class AvatarEncoder {
  static async load(uri: string): Promise<image.PixelMap | null> {
    let file: fileIo.File | null = null;
    let source: image.ImageSource | null = null;
    try {
      file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      if (fileIo.statSync(file.fd).size > 20 * 1024 * 1024) return null;
      source = image.createImageSource(file.fd);
      const info: image.ImageInfo = await source.getImageInfo();
      if (info.size.width <= 0 || info.size.height <= 0) return null;
      const ratio: number = Math.min(1, 1024 / Math.max(info.size.width, info.size.height));
      return await source.createPixelMap({ editable: true, desiredSize: {
        width: Math.max(1, Math.round(info.size.width * ratio)),
        height: Math.max(1, Math.round(info.size.height * ratio))
      } });
    } catch (error) {
      return null;
    } finally {
      try { if (source !== null) await source.release(); } catch (error) { /* Continue releasing. */ }
      try { if (file !== null) fileIo.closeSync(file); } catch (error) { /* Already closed. */ }
    }
  }

  static async encodeCrop(preview: image.PixelMap, region: AvatarCropRect): Promise<string> {
    let pixels: image.PixelMap | null = null;
    let packer: image.ImagePacker | null = null;
    try {
      // Keep the preview intact so cancellation and a failed encode never destroy it.
      pixels = await preview.clone();
      await pixels.crop({ x: region.x, y: region.y, size: { width: region.side, height: region.side } });
      await pixels.scale(256 / region.side, 256 / region.side);
      packer = image.createImagePacker();
      const packed: ArrayBuffer = await packer.packing(pixels, { format: 'image/jpeg', quality: 80 });
      if (packed.byteLength > 128 * 1024) return '';
      return 'data:image/jpeg;base64,' + new util.Base64Helper().encodeToStringSync(new Uint8Array(packed));
    } catch (error) {
      return '';
    } finally {
      try { if (packer !== null) await packer.release(); } catch (error) { /* Continue releasing. */ }
      try { if (pixels !== null) await pixels.release(); } catch (error) { /* Continue releasing. */ }
    }
  }
}
