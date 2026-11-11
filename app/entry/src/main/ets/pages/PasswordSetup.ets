import { PageHeader } from '../components/PageHeader';
import { UiTheme } from '../utils/UiTheme';
import router from '@ohos.router';
import { AgentApiClient } from '../api/AgentApiClient';
import { ApiFailure } from '../api/ApiResult';
import { AuthStore } from '../api/AuthStore';
import { AuthClient } from '../api/AuthClient';
import { appState } from '../data/AppState';

@Entry
@Component
struct PasswordSetup {
  @State password: string = '';
  @State repeat: string = '';
  @State message: string = '';
  @State busy: boolean = false;
  onBackPress(): boolean { this.confirmLeave(); return true; }
  private confirmLeave(): void {
    AlertDialog.show({ title: '暂不设置密码？', message: '返回登录页后，可以通过手机号验证继续设置。',
      primaryButton: { value: '继续设置', action: () => {} },
      secondaryButton: { value: '返回登录', action: async () => {
        await AuthClient.signOut(); appState.applyLogout(); router.replaceUrl({ url: 'pages/Login' });
      } } });
  }
  private async save(): Promise<void> {
    if (this.busy) return;
    if (this.password.length < 6 || this.password.length > 72 || this.password !== this.repeat) { this.message = '请填写6至72位密码，并确认两次输入一致'; return; }
    const owner: string = AuthStore.getUserId();
    this.busy = true;
    const result = await AgentApiClient.authChangePassword({ newPassword: this.password });
    if (owner !== AuthStore.getUserId()) return;
    this.busy = false;
    if (!result.ok) { this.message = (result as ApiFailure).error.message; return; }
    this.password = ''; this.repeat = '';
    router.replaceUrl({ url: 'pages/ChatMain' });
  }
  build() {
    Column() {
      PageHeader({ title: '首次设置密码', onBack: () => this.confirmLeave() })
      Scroll() {
        Column({ space: 20 }) {
          Text('手机号已验证').fontSize(14).fontColor(UiTheme.accent).width('100%').padding(12).backgroundColor(UiTheme.tint).borderRadius(8)
          Text('请为你的账号设置登录密码，用于后续登录知学 Mate。').fontSize(14).fontColor(UiTheme.secondary).lineHeight(23).width('100%')
          Text('新密码').fontSize(14).fontColor(UiTheme.ink).width('100%')
          TextInput({ text: this.password, placeholder: '请输入新密码（6至72位）' }).type(InputType.Password).showPasswordIcon(true)
            .height(46).borderRadius(8).backgroundColor(UiTheme.subtle).maxLength(72).enabled(!this.busy).onChange((value: string) => this.password = value)
          Text('确认密码').fontSize(14).fontColor(UiTheme.ink).width('100%')
          TextInput({ text: this.repeat, placeholder: '请再次输入新密码' }).type(InputType.Password).showPasswordIcon(true)
            .height(46).borderRadius(8).backgroundColor(UiTheme.subtle).maxLength(72).enabled(!this.busy).onChange((value: string) => this.repeat = value)
          if (this.message) { Text(this.message).fontSize(13).fontColor(UiTheme.danger).width('100%') }
          Button(this.busy ? '保存中…' : '保存并进入', { type: ButtonType.Normal }).width('100%').height(46).fontSize(15)
            .fontColor('#FFFFFF').backgroundColor(UiTheme.accent).borderRadius(8).enabled(!this.busy).onClick(() => this.save())
          Text('数据说明').fontSize(16).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).width('100%').margin({ top: 24 })
          Text('首次设置适用于手机号验证后的新注册或找回密码流程。已有账号修改密码需要验证原密码。学习记录与账号绑定，可跨设备同步。')
            .fontSize(13).fontColor(UiTheme.secondary).lineHeight(22).width('100%')
        }.width('100%').constraintSize({ maxWidth: UiTheme.formWidth }).padding(24).alignItems(HorizontalAlign.Start)
      }.width('100%').layoutWeight(1).align(Alignment.Top)
    }.width('100%').height('100%').backgroundColor(UiTheme.surface)
  }
}
