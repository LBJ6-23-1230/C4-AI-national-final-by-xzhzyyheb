import { hvigor } from '@ohos/hvigor';
import { appTasks, OhosAppContext, OhosPluginId } from '@ohos/hvigor-ohos-plugin';
import { existsSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import '../tools/hvigor-resource-compat.cjs';

hvigor.getRootNode().afterNodeEvaluate((node) => {
    const mode = hvigor.getParameter().getExtParam('buildMode');
    if (mode && mode !== 'debug') return;

    const context = node.getContext(OhosPluginId.OHOS_APP_PLUGIN) as OhosAppContext;
    const profile = context.getBuildProfileOpt();
    const product = profile.app.products?.find((item) => item.name === 'default');
    if (!product || product.signingConfig || profile.app.signingConfigs?.length) return;

    const localSigning = resolve(__dirname, '../zhixue-signing/local-debug-signing.json');
    if (!existsSync(localSigning)) return;
    const configs = JSON.parse(readFileSync(localSigning, 'utf8')) as typeof profile.app.signingConfigs;
    if (!configs?.[0]?.name) throw new Error('The local debug signing configuration is empty.');
    profile.app.signingConfigs = configs;
    product.signingConfig = configs[0].name;
    context.setBuildProfileOpt(profile);
});

export default {
    system: appTasks,
    plugins: []
}
