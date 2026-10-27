import { image } from '@kit.ImageKit';
import { AvatarCropGeometry, AvatarCropRect } from '../utils/AvatarCropGeometry';

@Component
export struct AvatarCropper {
  pixels: image.PixelMap | undefined = undefined;
  imageWidth: number = 1;
  imageHeight: number = 1;
  @Prop busy: boolean = false;
  @Prop errorText: string = '';
  onConfirm: (region: AvatarCropRect) => void = (): void => {};
  onCancel: () => void = (): void => {};
  @State viewport: number = 280;
  @State zoom: number = 1;
  @State offsetX: number = 0;
  @State offsetY: number = 0;
  private panStartX: number = 0;
  private panStartY: number = 0;
  private pinchStartZoom: number = 1;

  private factor(): number {
    return AvatarCropGeometry.factor(this.imageWidth, this.imageHeight, this.viewport, this.zoom);
  }

  private clampPosition(): void {
    this.offsetX = AvatarCropGeometry.clampOffset(this.offsetX, this.imageWidth, this.factor(), this.viewport);
    this.offsetY = AvatarCropGeometry.clampOffset(this.offsetY, this.imageHeight, this.factor(), this.viewport);
  }

  private changeZoom(value: number): void {
    const next: number = Math.max(1, Math.min(4, value));
    this.offsetX *= next / this.zoom;
    this.offsetY *= next / this.zoom;
    this.zoom = next;
    this.clampPosition();
  }

  build() {
    Column() {
      Row() {
        Button('取消').fontSize(14).backgroundColor(Color.Transparent).fontColor('#64748B')
          .enabled(!this.busy).onClick(() => this.onCancel())
        Blank()
        Text('裁剪头像').fontSize(18).fontWeight(FontWeight.Bold).fontColor('#172033')
        Blank()
        Button('重置').fontSize(14).backgroundColor(Color.Transparent).fontColor('#2563EB')
          .enabled(!this.busy).onClick(() => { this.zoom = 1; this.offsetX = 0; this.offsetY = 0; })
      }.width('100%').padding(12).backgroundColor('#FFFFFF')
      Scroll() {
        Column({ space: 20 }) {
          Text('拖动图片调整位置，双指或滑动下方滑块缩放')
            .fontSize(13).fontColor('#667085').textAlign(TextAlign.Center)
          Stack() {
            if (this.pixels !== undefined) {
              Image(this.pixels).width(this.imageWidth * this.factor()).height(this.imageHeight * this.factor())
                .objectFit(ImageFit.Fill).translate({ x: this.offsetX, y: this.offsetY })
                .draggable(false).hitTestBehavior(HitTestMode.None)
            }
            Circle().width('100%').height('100%').fill(Color.Transparent)
              .stroke('#FFFFFF').strokeWidth(2).hitTestBehavior(HitTestMode.None)
          }.width('100%').aspectRatio(1).clip(true).backgroundColor('#111827')
            .border({ width: 1, color: '#CBD5E1' }).enabled(!this.busy)
            .accessibilityText('头像裁剪区域，可拖动图片调整位置')
            .onAreaChange((oldArea: Area, area: Area) => {
              const edge: number = Number(area.width);
              if (edge > 0 && edge !== this.viewport) {
                this.offsetX *= edge / this.viewport;
                this.offsetY *= edge / this.viewport;
                this.viewport = edge;
                this.clampPosition();
              }
            })
            .priorityGesture(GestureGroup(GestureMode.Parallel,
              PanGesture({ fingers: 1, direction: PanDirection.All, distance: 1 })
                .onActionStart(() => { this.panStartX = this.offsetX; this.panStartY = this.offsetY; })
                .onActionUpdate((event: GestureEvent) => {
                  this.offsetX = this.panStartX + event.offsetX;
                  this.offsetY = this.panStartY + event.offsetY;
                  this.clampPosition();
                }),
              PinchGesture({ fingers: 2 })
                .onActionStart(() => { this.pinchStartZoom = this.zoom; })
                .onActionUpdate((event: GestureEvent) => this.changeZoom(this.pinchStartZoom * event.scale))
            ))
          Row({ space: 12 }) {
            Text('缩小').fontSize(12).fontColor('#667085')
            Slider({ value: this.zoom, min: 1, max: 4, step: 0.01 }).layoutWeight(1)
              .enabled(!this.busy).onChange((value: number) => this.changeZoom(value))
            Text('放大').fontSize(12).fontColor('#667085')
          }.width('100%')
          Text('圆圈内为头像显示范围').fontSize(12).fontColor('#667085')
          if (this.errorText.length > 0) {
            Text(this.errorText).fontSize(13).fontColor('#B42318')
          }
          Button(this.busy ? '正在处理…' : '确认裁剪').width('100%').height(48)
            .fontSize(16).backgroundColor('#2563EB').enabled(!this.busy)
            .onClick(() => this.onConfirm(AvatarCropGeometry.region(this.imageWidth, this.imageHeight,
              this.viewport, this.zoom, this.offsetX, this.offsetY)))
        }.width('100%').constraintSize({ maxWidth: 460 }).padding(20)
      }.width('100%').layoutWeight(1)
    }.width('100%').height('100%').backgroundColor('#F3F6FA')
  }
}
