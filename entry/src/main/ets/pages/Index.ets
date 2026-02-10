import socket from '@ohos.net.socket';
import { BusinessError } from '@ohos.base';
import { PromptAction } from '@kit.ArkUI';
import { distributedKVStore } from '@kit.ArkData';
import KVStore from './KVStore';
import { KVStoreType } from './KVStoreType';
// 统一类型接口：MAC验证结果
interface MacValidateResult {
  isValid: boolean;
  msg: string;
  cleanMac?: string;
}


@Extend(Text)
function tableHeaderStyle() {
  .fontSize(18)
  .fontWeight(700)
  .fontColor($r('sys.color.mask_secondary'))
  .height(37)
  .textAlign(TextAlign.Center)
}

@Extend(Text)
function tableStyle() {
  .maxLines(1)
  .textOverflow({ overflow: TextOverflow.Ellipsis })
  .fontSize(14)
  .fontColor('#e6000000')
  .lineHeight(20)
  .textAlign(TextAlign.Center)
}

@Entry
@Component
struct WolCompleteFinalPage {
  // 状态管理
  @State macAddress: string = '';
  @State statusMsg: string = '';
  @State isSending: boolean = false;
  @State isSocketClosed: boolean = true;

  @State inputValue:string=''
  @StorageLink('kvStoreAll') kvStoreAll: KVStoreType[] = [];
  @StorageLink('encrypted') encrypted: boolean = false;
  @StorageLink('kvStore') kvStore: KVStore | undefined = undefined;

  private UIContext: UIContext = this.getUIContext();
  private promptAction: PromptAction = this.UIContext.getPromptAction();

  aboutToAppear(): void {
    this.kvStore = new KVStore(this.encrypted, distributedKVStore.SecurityLevel.S1, this.UIContext);

    setTimeout(async () => {
    await this.kvStore?.getAll().then((data) => {
      if(data.length===0){
        this.kvStoreAll = data;
        this.promptAction.showToast({
          message: '暂时没有历史记录',
          duration: 2000
        });
      }else{
        this.kvStoreAll = data;
      }

    });
  }, 200);
  }

  async put_data(inputValue:string)  {
    await this.kvStore?.put(inputValue, '存在');
    setTimeout(async () => {
      await this.kvStore?.getAll().then((data) => {
        this.kvStoreAll = data;
      });
    }, 200);
  }


  @Builder
  menuBuilder(kvStore: KVStoreType) {
    Flex({ direction: FlexDirection.Column, justifyContent: FlexAlign.Center, alignItems: ItemAlign.Center }) {
      Column() {
        Row() {
          SymbolGlyph($r('sys.symbol.paperplane'))
            .fontSize(24)
            .margin({ right: 8 })
          Text('发送')
            .fontSize(16)
            .fontWeight(500)
            .lineHeight(21)
            .fontColor('#e6000000')
        }
        .width('100%')
        .height(30)
        .justifyContent(FlexAlign.Start)
        .align(Alignment.Center)
        .enabled(!this.isSending)
        .onClick(()=>{
          this.macAddress=kvStore.key
          this.promptAction.showToast({
            message: '发送：'+this.macAddress,
            duration: 2000
          });
          this.sendWolPacket();
        })

        Divider()
          .height(10)
          .width('100%')
          .color('#0d000000')
        Row() {
          SymbolGlyph($r('sys.symbol.trash_fill'))
            .fontSize(24)
            .margin({ right: 8 })
          Text('删除')
            .fontSize(16)
            .fontWeight(500)
            .lineHeight(21)
            .fontColor('#e6000000')
        }
        .width('100%')
        .height(30)
        .justifyContent(FlexAlign.Start)
        .align(Alignment.Center)
        .onClick(async () => {
          this.kvStore?.delete(kvStore.key)
          setTimeout(async () => {
            await this.kvStore?.getAll().then((data: KVStoreType[]) => {
              this.kvStoreAll = data;
            });
          }, 200)
        })
      }
      .padding({
        top: 4,
        bottom: 4,
        left: 16,
        right: 16
      })
      .height(80)
    }
    .width(224)
  }


  /**
   * 1. 校验MAC地址合法性（支持格式：A1B2C3D4E5F6 / A1:B2:C3:D4:E5:F6 / A1-B2-C3-D4-E5-F6）
   */
  private validateMac(): MacValidateResult {
    const input = this.macAddress.trim();
    // 空输入校验
    if (!input) {
      return { isValid: false, msg: '请输入目标设备MAC地址' };
    }
    // 清理格式：移除分隔符并转大写
    const cleanMac = input.replace(/[:\-\s]/g, '').toUpperCase();
    // 长度+十六进制格式校验
    if (cleanMac.length !== 12 || !/^[0-9A-F]{12}$/.test(cleanMac)) {
      return {
        isValid: false,
        msg: 'MAC格式错误！支持：A1B2C3D4E5F6 或 A1:B2:C3:D4:E5:F6'
      };
    }
    this.put_data(cleanMac)
    return { isValid: true, msg: 'MAC校验通过', cleanMac };
  }

  /**
   * 2. 生成标准WOL魔术包（102字节：6字节FF前缀 + 16次MAC重复）
   * WOL协议标准：https://datatracker.ietf.org/doc/html/rfc2470
   */
  private buildMagicPacket(cleanMac: string): ArrayBuffer {
    // 第一步：将12位MAC转成6字节数组
    const macBytes = new Uint8Array(6);
    for (let i = 0; i < 12; i += 2) {
      macBytes[i / 2] = parseInt(cleanMac.substring(i, i + 2), 16);
    }

    // 第二步：构建102字节魔术包
    const magicPacket = new Uint8Array(102);
    // 前6字节：全FF（唤醒信号前缀）
    magicPacket.set(new Uint8Array(6).fill(0xff), 0);
    // 后96字节：MAC地址重复16次（6*16=96）
    for (let i = 0; i < 16; i++) {
      magicPacket.set(macBytes, 6 + i * 6);
    }
    return magicPacket.buffer;
  }

  /**
   * 3. 核心：发送WOL唤醒包（完整Socket生命周期管理，无资源泄漏）
   */
  private async sendWolPacket() {

    if (this.isSending) {
      this.statusMsg = '⏳ 正在发送中，请勿重复点击';
      return;
    }

    // 初始化状态与变量
    this.isSending = true;
    this.statusMsg = '⏳ 正在生成唤醒包...';
    this.isSocketClosed = true;
    let udpSocket: socket.UDPSocket | null = null;

    try {
      // 步骤1：校验MAC地址
      const macResult = this.validateMac();
      if (!macResult.isValid) {
        this.statusMsg = `❌ ${macResult.msg}`;
        return;
      }
      const cleanMac = macResult.cleanMac!; // 已校验isValid，非undefined

      // 步骤3：创建UDP Socket实例
      udpSocket = socket.constructUDPSocketInstance();
      if (!udpSocket) {
        throw new Error('Socket实例创建失败，可能是系统资源不足');
      }
      this.isSocketClosed = false;
      this.statusMsg = '⏳ 正在初始化网络连接...';

      // 步骤4：Bind本地地址（必须先Bind，否则Send会报无效描述符）
      let bindAddr: socket.NetAddress = {
        address: '255.255.255.255',
        port: 9
      }
      udpSocket.bind(bindAddr, (err: BusinessError) => {
        if (err) {
          console.log('bind fail');
          return;
        }
        console.log('bind success');
      });
      this.statusMsg = '⏳ 正在开启广播权限...';

      // 步骤5：开启广播权限（Send广播包必须开启，异步需await）
      await udpSocket.setExtraOptions({ broadcast: true });

      // 步骤6：生成魔术包
      const magicPacket:ArrayBuffer = this.buildMagicPacket(cleanMac);
      this.statusMsg = '⏳ 正在发送唤醒包...';

      // 步骤7：发送唤醒包（使用官方标准NetAddress）
      let netAddress: socket.NetAddress = {
        address: '255.255.255.255',
        port: 9,
        family: 1
      }
      let sendOptions: socket.UDPSendOptions = {
        address: netAddress,
        data: magicPacket,

      }
      udpSocket.send(sendOptions, (err: BusinessError) => {
        if (err) {
          console.log('send fail');
          return;
        }
        console.log('send success');
      });

      // 步骤8：发送成功
      this.statusMsg = `✅ 唤醒包发送成功！\n目标：${cleanMac}`;
      console.log(`WOL发送成功：MAC=${cleanMac}, `);

    } catch (error) {
      // 错误处理：区分常见错误类型
      const err = error as BusinessError;
      let errorMsg = '';
      // 常见Socket错误码映射（参考鸿蒙官方文档）
      switch (err.code) {
        case 2301001:
          errorMsg = '无网络权限（需重新申请）';
          break;
        case 2301009:
          errorMsg = 'Socket描述符无效（可能是重复关闭或未Bind）';
          break;
        case 2301013:
          errorMsg = '网络不可达（检查设备是否联网）';
          break;
        case 2301014:
          errorMsg = '端口不可用（目标设备端口未开放）';
          break;
        default:
          errorMsg = `${err.message || '未知错误'}（错误码：${err.code || '未知'}）`;
      }
      this.statusMsg = `❌ 发送失败：${errorMsg}`;
      console.error('WOL发送错误:', err.code, err.message);

    } finally {
      // 关键：无论成功/失败，都关闭Socket（避免资源泄漏）
      if (udpSocket && !this.isSocketClosed) {
        try {
          await udpSocket.close();
          this.isSocketClosed = true;
          console.log('Socket已正常关闭');
        } catch (closeErr) {
          this.isSocketClosed = true;
          console.error('Socket关闭失败:', (closeErr as BusinessError).message);
        }
      }
      // 恢复发送状态
      this.isSending = false;
    }
  }

  /**
   * 4. UI渲染（简洁易用，适配手机端，状态提示清晰）
   */
  build() {
    Column({ space: 20 }) {
      // 标题栏（固定顶部）
      Row() {
        Text('网络唤醒工具 (WOL)')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)

      }
      .width('100%')
      .height(56)
      .padding(16)
      .backgroundColor('#007AFF')
      .alignItems(VerticalAlign.Center);

      // 核心内容区（垂直居中）
      Column({ space: 16 }) {
        // 权限状态提示
        Text(this.statusMsg)
          .fontSize(14)

          .width('90%')
          .textAlign(TextAlign.Center);

        // 1. MAC地址输入框
        TextInput({
          placeholder: '输入MAC地址（例：A1:B2:C3:D4:E5:F6）',
          text: this.macAddress
        })
          .width('90%')
          .height(50)
          .padding({ left: 16, right: 16 })
          .fontSize(16)
          .backgroundColor('#FFFFFF')
          .borderRadius(8)
          .onChange((value: string) => {
            this.macAddress = value; // 保留原始输入，校验时统一清理格式
          });

        // 2. 发送按钮（发送中禁用，避免重复触发）
        Button(this.isSending ? '发送中...' : '发送唤醒包')
          .width('70%')
          .height(52)
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .backgroundColor('#007AFF')

          .borderRadius(8)
          .enabled(!this.isSending)
          .onClick(() => {
            this.sendWolPacket(); // 调用核心发送方法
          });

        // 5. 注意事项（硬件配置提醒，降低用户排查成本）
        Text('⚠️ 唤醒失败排查：\n1. 目标设备BIOS/网卡已开启WOL\n2. 目标设备已通电（待机供电）\n3. 跨网段需配置路由器端口转发')
          .fontSize(12)

          .width('90%')
          .textAlign(TextAlign.Center)
          .margin({ top: 10 })
          .lineHeight(20); // 调整行高，避免文字重叠


        Column() {
          Row() {
            Text('历史MAC')
              .width('80%')
              .tableHeaderStyle()
              .textAlign(TextAlign.Start)
            Text('操作')
              .tableHeaderStyle()
          }
          .justifyContent(FlexAlign.Start)
          .padding({ right: 11 })
          .width('100%')
          .height(44)

          Divider()
            .padding({
              left: 10,
              right: 10
            })
            .width('100%')
            .color('#0d000000')

          ForEach(this.kvStoreAll, (kvStore: KVStoreType) => {
            Row() {
              Text(kvStore.key)
                .width('80%')
                .tableStyle()
                .textAlign(TextAlign.Start)
              SymbolGlyph($r('sys.symbol.dot_grid_1x2'))
                .fontSize(20)
                .fontColor(['#99000000'])
                .bindMenu(this.menuBuilder(kvStore))
            }
            .justifyContent(FlexAlign.Start)
            .margin({
              top: 8,
              bottom: 12
            })
            .width('100%')
            .height(20)
          }, (kvStore: KVStoreType) => JSON.stringify(kvStore))

        }
        .padding(12)
        .width('100%')
        .borderRadius(12)
        .backgroundColor(Color.White)


      }
      .width('100%')
      .padding(20);

    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F5F7FA') // 浅色背景，提升视觉舒适度
    .justifyContent(FlexAlign.Start) // 内容从顶部开始，避免标题栏偏移
    .padding({ top: 0 }); // 取消顶部内边距，确保标题栏贴顶
  }
}
