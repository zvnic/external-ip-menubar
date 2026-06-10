# Подпись и нотаризация (для переноса на другие Mac)

Ad-hoc подпись (по умолчанию в `build.sh`) работает только на этой машине.
Чтобы `.app` запускался на чужих Mac без предупреждений Gatekeeper, нужны
**Developer ID** подпись и **нотаризация**. Для этого требуется платный аккаунт
Apple Developer ($99/год).

## 1. Сборка с Developer ID

```bash
# Посмотреть доступные сертификаты:
security find-identity -v -p codesigning

# Собрать с подписью Developer ID (hardened runtime включается автоматически):
SIGN_IDENTITY="Developer ID Application: Ваше Имя (TEAMID)" ./build.sh
```

## 2. Нотаризация

Один раз сохраните учётные данные в keychain (нужен app-specific password
с appleid.apple.com):

```bash
xcrun notarytool store-credentials notary-profile \
    --apple-id "you@example.com" \
    --team-id "TEAMID" \
    --password "xxxx-xxxx-xxxx-xxxx"
```

Затем заархивируйте, отправьте на нотаризацию и прикрепите тикет:

```bash
ditto -c -k --keepParent build/ExternalIPMenuBar.app build/ExternalIPMenuBar.zip
xcrun notarytool submit build/ExternalIPMenuBar.zip \
    --keychain-profile notary-profile --wait
xcrun stapler staple build/ExternalIPMenuBar.app
```

После этого `.app` можно копировать на любой Mac.
