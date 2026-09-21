import { randomUUID } from "node:crypto";
import { writeFile } from "node:fs/promises";
import path from "node:path";

function pemBlocks(value, label) {
  const pattern = new RegExp(`-----BEGIN ${label}-----[\\s\\S]+?-----END ${label}-----`, "g");
  return value.match(pattern) || [];
}

export function parseKeyVaultPem(value) {
  const text = String(value || "");
  const privateKeys = [
    ...pemBlocks(text, "PRIVATE KEY"),
    ...pemBlocks(text, "RSA PRIVATE KEY"),
    ...pemBlocks(text, "EC PRIVATE KEY"),
  ];
  const certificates = pemBlocks(text, "CERTIFICATE");
  if (privateKeys.length !== 1 || certificates.length < 1) {
    throw new Error("Key Vault certificate secret must contain one PEM private key followed by its PEM certificate chain");
  }
  return {
    privateKey: `${privateKeys[0]}\n`,
    x5c: certificates.map((block) => `${block}\n`).join(""),
  };
}

export async function loadBotCertificate(secretClient, certificateName) {
  const secret = await secretClient.getSecret(certificateName);
  if (!secret.value) throw new Error(`Key Vault certificate ${certificateName} has no secret value`);
  const material = parseKeyVaultPem(secret.value);
  return { ...material, version: secret.properties.version };
}

export async function materializeBotCertificate(material, directory = "/tmp") {
  const stem = path.join(directory, `firstmate-teams-cert-${process.pid}-${randomUUID()}`);
  const certificatePath = `${stem}.pem`;
  const privateKeyPath = `${stem}.key`;
  await writeFile(certificatePath, material.x5c, { mode: 0o600, flag: "wx" });
  try {
    await writeFile(privateKeyPath, material.privateKey, { mode: 0o600, flag: "wx" });
  } catch (error) {
    const { unlink } = await import("node:fs/promises");
    await unlink(certificatePath).catch(() => {});
    throw error;
  }
  return { certificatePath, privateKeyPath };
}
