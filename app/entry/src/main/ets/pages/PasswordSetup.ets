import router from '@ohos.router';
import { AgentApiClient } from '../api/AgentApiClient';
import { ApiFailure } from '../api/ApiResult';
import { AuthStore } from '../api/AuthStore';

@Entry
@Component
struct PasswordSetup {
  @State password: string = '';
  @State repeat: string = '';
  @State message: string = '';
  @State busy: boolean = false;
  onBackPress(): boolean { return true; }
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
    Column({ space: 18 }) {
      Text('首次设置密码').fontSize(24).fontWeight(FontWeight.Bold)
      Text('手机号验证已完成。请设置密码，以后用同一个手机号登录。').fontColor('#667085')
      TextInput({ text: this.password, placeholder: '6至72位密码' }).type(InputType.Password).maxLength(72).onChange((value: string) => this.password = value)
      TextInput({ text: this.repeat, placeholder: '再次输入密码' }).type(InputType.Password).maxLength(72).onChange((value: string) => this.repeat = value)
      Text(this.message).fontColor('#B42318')
      Button(this.busy ? '保存中…' : '保存并进入').enabled(!this.busy).onClick(() => this.save())
    }.width('100%').height('100%').padding(24).justifyContent(FlexAlign.Center)
  }
}
