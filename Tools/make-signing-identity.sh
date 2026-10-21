#!/bin/bash
# 建一个本机自签的代码签名身份，让 ad-hoc 构建的钥匙串授权能固定下来。
#
# 为什么要它：`codesign -s -` 每次构建 cdhash 都变，钥匙串按签名认人，于是每次重新构建
# 都要重新授权一次读 WebDAV 应用密码。换成固定证书签名后，cdhash 变了但签名身份不变，
# 「始终允许」点一次就永久生效。
#
# 私钥只进登录钥匙串，脚本跑完就删掉中间的 PEM/P12。
set -euo pipefail

NAME="DeskNote Local"
DAYS=3650
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning 2>/dev/null | grep -q "\"$NAME\""; then
    echo "已存在签名身份：$NAME"
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
O = local.desknote.app
[ext]
basicConstraints = critical,CA:TRUE
keyUsage = critical,digitalSignature,keyEncipherment,keyCertSign
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days "$DAYS" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -config "$TMP/openssl.cnf" -extensions ext 2>/dev/null

# p12 口令只是导入导出时的一次性包装，不落盘
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/identity.p12" -passout pass:desknote-local -name "$NAME"

security import "$TMP/identity.p12" -k "$KEYCHAIN" -f pkcs12 \
    -P desknote-local -T /usr/bin/codesign >/dev/null

echo "已创建并导入签名身份：$NAME"
security find-identity -p codesigning | grep "$NAME"
