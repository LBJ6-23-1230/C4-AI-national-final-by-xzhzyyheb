@echo off
chcp 65001 >nul
setlocal
set "P12=%~1"
if not defined P12 (
  echo 用法: 读取密钥别名.bat "本机密钥库.p12"
  exit /b 1
)
if not exist "%P12%" (
  echo 找不到指定密钥库。
  exit /b 1
)
if defined JAVA_HOME (
  "%JAVA_HOME%\bin\keytool.exe" -list -v -keystore "%P12%" -storetype PKCS12
) else (
  keytool -list -v -keystore "%P12%" -storetype PKCS12
)
exit /b %errorlevel%
