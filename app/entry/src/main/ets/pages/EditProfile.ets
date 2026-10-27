import router from '@ohos.router';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { promptAction } from '@kit.ArkUI';
import { AuthClient } from '../api/AuthClient';
import { AuthResult } from '../api/AuthResult';
import { appState } from '../data/AppState';
import { UserAvatar } from '../components/UserAvatar';
import { AvatarEncoder } from '../utils/AvatarEncoder';
import { image } from '@kit.ImageKit';
import { AvatarCropper } from '../components/AvatarCropper';
import { AvatarCropRect } from '../utils/AvatarCropGeometry';

@Entry
@Component
struct EditProfile {
  @State nickname: string = '';
  @State avatar: string = '';
  @State busy: boolean = false;
  @State picking: boolean = false;
  @State message: string = '';
  @State cropPixels: image.PixelMap | undefined = undefined;
  @State cropWidth: number = 1;
  @State cropHeight: number = 1;
  private originalNickname: string = '';
  private originalAvatar: string = '';
  private owner: string = '';
  private active: boolean = false;

  aboutToAppear(): void {
    this.active = true;
    this.owner = appState.currentUser.userId;
    this.nickname = appState.authNickname;
    this.avatar = appState.authAvatar;
    this.originalNickname = this.nickname;
    this.originalAvatar = this.avatar;
  }

  aboutToDisappear(): void { this.active = false; this.cancelCrop(); }
  onBackPress(): boolean {
    if (this.busy || this.picking) return true;
    if (this.cropPixels !== undefined) { this.cancelCrop(); return true; }
    return false;
  }

  private cancelCrop(): void {
    const pixels: image.PixelMap | undefined = this.cropPixels;
    this.cropPixels = undefined;
    this.message = '';
    if (pixels !== undefined) void pixels.release().catch(() => {});
  }

  private async confirmCrop(region: AvatarCropRect): Promise<void> {
    if (this.cropPixels === undefined || this.picking) return;
    this.picking = true;
    this.message = '';
    const encoded: string = await AvatarEncoder.encodeCrop(this.cropPixels, region);
    this.picking = false;
    if (!this.active || this.owner !== appState.currentUser.userId) return;
    if (encoded.length === 0) {
      this.message = '裁剪失败，请调整后重试。';
      return;
    }
    this.avatar = encoded;
    this.cancelCrop();
  }

  private changed(): boolean {
    return this.nickname.trim() !== this.originalNickname || this.avatar !== this.originalAvatar;
  }

  private async pickAvatar(): Promise<void> {
    if (this.busy || this.picking) return;
    this.picking = true;
    this.message = '';
    try {
      const picker = new photoAccessHelper.PhotoViewPicker();
      const options = new photoAccessHelper.PhotoSelectOptions();
      options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      options.maxSelectNumber = 1;
      const result = await picker.select(options);
      if (result.photoUris.length === 0) return;
      const pixels: image.PixelMap | null = await AvatarEncoder.load(result.photoUris[0]);
      if (pixels === null) {
        this.message = '图片处理失败，请选择一张 20MB 以内的图片重试。';
        return;
      }
      if (!this.active || this.owner !== appState.currentUser.userId) {
        await pixels.release();
        return;
      }
      const info: image.ImageInfo = await pixels.getImageInfo();
      this.cropWidth = info.size.width;
      this.cropHeight = info.size.height;
      this.cropPixels = pixels;
    } catch (error) {
      if (this.active) this.message = '未能选择图片，请重试。';
    } finally {
      this.picking = false;
    }
  }

  private async save(): Promise<void> {
    if (this.busy || this.picking || !this.changed()) return;
    this.message = AuthClient.validateNickname(this.nickname);
    if (this.message.length > 0) return;
    if (this.owner !== appState.currentUser.userId) return;
    this.busy = true;
    const result: AuthResult = await AuthClient.updateProfile(this.nickname, this.avatar);
    this.busy = false;
    if (!this.active || this.owner !== appState.currentUser.userId) return;
    if (!result.ok || result.user === null) {
      this.message = result.message;
      return;
    }
    appState.applyLogin(result.user, appState.authSource, appState.loginNotice);
    promptAction.showToast({ message: result.message });
    router.back();
  }

  @Builder
  private ProfileContent() {
    Column() {
      Row() {
        Button('返回').fontSize(14).fontColor('#64748B').backgroundColor(Color.Transparent)
          .enabled(!this.busy && !this.picking).onClick(() => router.back())
        Blank()
        Text('编辑资料').fontSize(18).fontWeight(FontWeight.Bold).fontColor('#172033')
        Blank()
        Blank().width(60)
      }.width('100%').padding(12).backgroundColor('#FFFFFF')
      Scroll() {
        Column({ space: 20 }) {
          if (appState.isSignedIn) {
            Column({ space: 12 }) {
              UserAvatar({ source: this.avatar, nickname: this.nickname, diameter: 88 })
              Button(this.picking ? '正在处理图片…' : '更换头像')
                .fontSize(14).fontColor('#2563EB').backgroundColor('#EFF6FF')
                .enabled(!this.busy && !this.picking).onClick(() => { void this.pickAvatar(); })
              Text('选图后可拖动、缩放裁剪，保存前可预览').fontSize(12).fontColor('#667085')
              if (this.avatar.length > 0) {
                Button('使用默认头像').fontSize(12).fontColor('#667085').backgroundColor(Color.Transparent)
                  .enabled(!this.busy && !this.picking).onClick(() => this.avatar = '')
              }
            }.width('100%').padding(24).backgroundColor('#FFFFFF').borderRadius(16)
            Column({ space: 10 }) {
              Text('昵称').fontSize(15).fontWeight(FontWeight.Medium).fontColor('#172033')
              TextInput({ text: this.nickname, placeholder: '请输入昵称' }).maxLength(16)
                .height(48).fontSize(16).backgroundColor('#F5F7FA')
                .enabled(!this.busy).onChange((value: string) => { this.nickname = value; this.message = ''; })
              Text(`${this.nickname.length}/16`).fontSize(12).fontColor('#667085')
            }.alignItems(HorizontalAlign.Start).width('100%').padding(18).backgroundColor('#FFFFFF').borderRadius(16)
            if (this.message.length > 0) {
              Text(this.message).fontSize(13).fontColor('#B42318').width('100%')
            }
            Button(this.busy ? '正在保存…' : '保存')
              .width('100%').height(48).fontSize(16).backgroundColor('#2563EB')
              .enabled(!this.busy && !this.picking && this.changed() && this.nickname.trim().length > 0)
              .onClick(() => { void this.save(); })
          } else {
            Text('登录后即可设置头像和昵称').fontSize(16).fontColor('#475467')
            Button('去登录').onClick(() => router.pushUrl({ url: 'pages/Login' }))
          }
        }.width('100%').constraintSize({ maxWidth: 560 }).padding(20)
      }.layoutWeight(1).width('100%')
    }.width('100%').height('100%').backgroundColor('#F3F6FA')
  }

  build() {
    if (this.cropPixels !== undefined) {
      AvatarCropper({ pixels: this.cropPixels, imageWidth: this.cropWidth, imageHeight: this.cropHeight,
        busy: this.picking, errorText: this.message,
        onConfirm: (region: AvatarCropRect): void => { void this.confirmCrop(region); },
        onCancel: (): void => this.cancelCrop() })
    } else {
      this.ProfileContent()
    }
  }
}
