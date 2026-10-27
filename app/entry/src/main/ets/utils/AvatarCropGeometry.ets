export interface AvatarCropRect {
  x: number;
  y: number;
  side: number;
}

/** Preview and saved crop share the same pixel-to-viewport transform. */
export class AvatarCropGeometry {
  static factor(width: number, height: number, viewport: number, zoom: number): number {
    return viewport / Math.min(width, height) * zoom;
  }

  static clampOffset(offset: number, length: number, factor: number, viewport: number): number {
    const limit: number = Math.max(0, (length * factor - viewport) / 2);
    return Math.max(-limit, Math.min(limit, offset));
  }

  static region(width: number, height: number, viewport: number, zoom: number,
    offsetX: number, offsetY: number): AvatarCropRect {
    const factor: number = AvatarCropGeometry.factor(width, height, viewport, zoom);
    const side: number = Math.max(1, Math.min(width, height, Math.floor(viewport / factor)));
    const x: number = Math.round((width - side) / 2 - offsetX / factor);
    const y: number = Math.round((height - side) / 2 - offsetY / factor);
    return { x: Math.max(0, Math.min(width - side, x)),
      y: Math.max(0, Math.min(height - side, y)), side: side };
  }
}
