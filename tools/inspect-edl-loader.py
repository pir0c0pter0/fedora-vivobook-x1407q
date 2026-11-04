#!/usr/bin/env python3
"""Triagem estrutural offline de programmers EDL; não autoriza transmissão."""

from __future__ import annotations

import argparse
import hashlib
import struct
from dataclasses import dataclass
from pathlib import Path


TARGET_HWID = "002ad0e100290000"
TARGET_PK_HASH = (
    "fd5f133f0db1b89904e66a74d242fb5edc5760b35d24793ffc7cc077b73fdcadd"
    "70f59436a9dd53f8004c37e3340e1f7"
)
TARGET_SOC_VERSIONS = (0xA009, 0xA016)
TARGET_OEM_ID = 0x29
TARGET_MODEL_ID = 1
MAX_SIZE = 128 * 1024 * 1024


class AnalysisError(ValueError):
    pass


@dataclass(frozen=True)
class MetadataV7:
    software_id: int
    soc_versions: tuple[int, ...]
    hardware_id: int
    oem_id: int
    model_id: int
    flags: int
    use_soc_versions: bool
    use_hardware_id: bool
    use_serial_number: bool
    use_oem_id: bool
    use_model_id: bool


@dataclass(frozen=True)
class Result:
    compatible: bool
    reason: str
    elf_count: int
    devprg_stage: int | None
    root_hash: str | None
    storage_markers: tuple[str, ...]
    metadata: MetadataV7 | None


def _elf_offsets(data: bytes) -> list[int]:
    offsets = []
    pos = 0
    while (pos := data.find(b"\x7fELF", pos)) != -1:
        elf_class = data[pos + 4] if pos + 7 <= len(data) else 0
        if data[pos + 5:pos + 7] == b"\x01\x01" and elf_class in (1, 2):
            header_size, phoff_at, phinfo_at, minimum_phdr = (
                (52, 28, 42, 32) if elf_class == 1 else (64, 32, 54, 56)
            )
            if pos + header_size <= len(data):
                phoff = struct.unpack_from(
                    "<I" if elf_class == 1 else "<Q", data, pos + phoff_at
                )[0]
                phentsize, phnum = struct.unpack_from("<HH", data, pos + phinfo_at)
                table_end = pos + phoff + phentsize * phnum
                if phentsize >= minimum_phdr and 0 < phnum <= 64 and table_end <= len(data):
                    offsets.append(pos)
        pos += 4
    return offsets


def _signed_segments(stage: bytes) -> list[bytes]:
    elf32 = stage[4] == 1
    phoff = struct.unpack_from(
        "<I" if elf32 else "<Q", stage, 28 if elf32 else 32
    )[0]
    phentsize, phnum = struct.unpack_from("<HH", stage, 42 if elf32 else 54)
    segments = []
    for index in range(phnum):
        entry = phoff + index * phentsize
        p_type = struct.unpack_from("<I", stage, entry)[0]
        if elf32:
            offset = struct.unpack_from("<I", stage, entry + 4)[0]
            size = struct.unpack_from("<I", stage, entry + 16)[0]
            flags = struct.unpack_from("<I", stage, entry + 24)[0]
        else:
            flags = struct.unpack_from("<I", stage, entry + 4)[0]
            offset = struct.unpack_from("<Q", stage, entry + 8)[0]
            size = struct.unpack_from("<Q", stage, entry + 32)[0]
        if offset + size > len(stage):
            raise AnalysisError("segmento ELF ultrapassa o fim do estágio")
        if p_type == 0 and flags & 0x0F000000 == 0x02000000 and size:
            segments.append(stage[offset:offset + size])
    return segments


def _der_hashes(data: bytes) -> list[str]:
    hashes = []
    pos = 0
    while (pos := data.find(b"0\x82", pos)) != -1:
        size = int.from_bytes(data[pos + 2:pos + 4], "big") + 4
        if size > 4 and pos + size <= len(data):
            hashes.append(hashlib.sha384(data[pos:pos + size]).hexdigest())
            pos += size
        else:
            pos += 2
    return hashes


def _v7_flag(flags: int, shift: int) -> bool:
    value = (flags >> shift) & 0b11
    if value not in (1, 2):
        raise AnalysisError(f"flags MBN v7 inválidas no bit {shift}")
    return value == 2


def _parse_mbn_v7(segment: bytes) -> tuple[MetadataV7, list[str]] | None:
    if len(segment) < 40:
        return None
    header = struct.unpack_from("<10I", segment)
    if header[1] != 7:
        return None

    common_size, qti_metadata_size, metadata_size = header[2:5]
    if common_size != 24 or metadata_size != 224:
        raise AnalysisError("tamanhos de metadata MBN v7 inesperados")
    total = 40 + sum(header[2:10])
    if total > len(segment) or any(value != 0xFF for value in segment[total:]):
        raise AnalysisError("tamanhos do cabeçalho MBN v7 não fecham o segmento")

    common_offset = 40
    metadata_offset = common_offset + common_size + qti_metadata_size
    software_id = struct.unpack_from("<I", segment, common_offset + 8)[0]
    soc_versions = tuple(
        value
        for value in struct.unpack_from("<12I", segment, metadata_offset + 16)
        if value
    )
    hardware_id = struct.unpack_from("<I", segment, metadata_offset + 68)[0]
    oem_id, model_id = struct.unpack_from("<II", segment, metadata_offset + 136)
    flags = struct.unpack_from("<I", segment, metadata_offset + 220)[0]
    metadata = MetadataV7(
        software_id=software_id,
        soc_versions=soc_versions,
        hardware_id=hardware_id,
        oem_id=oem_id,
        model_id=model_id,
        flags=flags,
        use_soc_versions=_v7_flag(flags, 0),
        use_hardware_id=_v7_flag(flags, 4),
        use_serial_number=_v7_flag(flags, 6),
        use_oem_id=_v7_flag(flags, 8),
        use_model_id=_v7_flag(flags, 10),
    )

    cert_size = header[9]
    cert_offset = total - cert_size
    return metadata, _der_hashes(segment[cert_offset:total])


def inspect(path: Path) -> Result:
    try:
        size = path.stat().st_size
    except OSError as exc:
        raise AnalysisError(str(exc)) from exc
    if not 0 < size <= MAX_SIZE:
        raise AnalysisError("tamanho inválido ou acima de 128 MiB")

    try:
        data = path.read_bytes()
    except OSError as exc:
        raise AnalysisError(str(exc)) from exc

    offsets = _elf_offsets(data)
    if not offsets:
        raise AnalysisError("nenhum ELF little-endian válido")
    stages = [
        data[start:end] for start, end in zip(offsets, offsets[1:] + [len(data)])
    ]
    devprg = [index for index, stage in enumerate(stages, 1) if b"devprg_entry.c" in stage]
    devprg_stage = devprg[0] if len(devprg) == 1 else None
    signed = [] if devprg_stage is None else _signed_segments(stages[devprg_stage - 1])
    parsed = [item for segment in signed if (item := _parse_mbn_v7(segment))]
    metadata = parsed[0][0] if len(parsed) == 1 else None
    hashes = parsed[0][1] if len(parsed) == 1 else []
    root_hash = (
        TARGET_PK_HASH
        if TARGET_PK_HASH in hashes
        else (hashes[-1] if hashes else None)
    )
    lower = data.lower()
    storage = tuple(name for name in ("nvme", "ufs", "emmc", "spinor") if name.encode() in lower)

    checks = (
        (len(stages) == 5, f"esperados 5 estágios ELF, encontrados {len(stages)}"),
        (len(devprg) == 1, "marcador devprg_entry.c ausente ou ambíguo"),
        (b"hamoa" in lower, "marcador Hamoa ausente"),
        (bool(signed), "segmento de assinatura Qualcomm ausente no devprg"),
        (len(parsed) == 1, "metadata Qualcomm MBN v7 ausente ou ambígua"),
        (
            metadata is not None
            and metadata.use_soc_versions
            and set(TARGET_SOC_VERSIONS).issubset(metadata.soc_versions),
            "SoC versions A009/A016 não correspondem ao Hamoa alvo",
        ),
        (
            metadata is not None
            and metadata.use_oem_id
            and metadata.oem_id == TARGET_OEM_ID,
            "OEM ID do metadata não corresponde a 0x29",
        ),
        (
            metadata is not None
            and metadata.use_model_id
            and metadata.model_id == TARGET_MODEL_ID,
            "model ID do metadata não corresponde ao perfil ASUS oficial",
        ),
        (
            metadata is not None
            and not metadata.use_hardware_id
            and not metadata.use_serial_number,
            "metadata exige hardware ID ou serial que não podem ser validados offline",
        ),
        (TARGET_PK_HASH in hashes, "raiz SHA-384 ASUS não corresponde ao alvo"),
    )
    for passed, reason in checks:
        if not passed:
            return Result(
                False,
                reason,
                len(stages),
                devprg_stage,
                root_hash,
                storage,
                metadata,
            )
    return Result(
        True,
        "todos os identificadores offline correspondem",
        len(stages),
        devprg_stage,
        root_hash,
        storage,
        metadata,
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("loader", type=Path, help="programmer .melf/.elf a analisar")
    args = parser.parse_args()
    try:
        result = inspect(args.loader)
    except AnalysisError as exc:
        print(f"ERRO: {exc}")
        return 2

    print(
        "PASSOU NA TRIAGEM ESTRUTURAL"
        if result.compatible
        else "REJEITADO NA TRIAGEM ESTRUTURAL"
    )
    print(f"Motivo: {result.reason}")
    print(
        f"ELFs: {result.elf_count}; "
        f"devprg: estágio {result.devprg_stage or 'não encontrado'}"
    )
    print(f"HWID esperado: {TARGET_HWID}")
    print(f"Raiz SHA-384: {result.root_hash or 'não encontrada'}")
    if result.metadata:
        soc = ", ".join(f"{value:04x}" for value in result.metadata.soc_versions)
        print(
            f"MBN v7: SoC {soc}; OEM {result.metadata.oem_id:04x}; "
            f"modelo {result.metadata.model_id:04x}; flags {result.metadata.flags:08x}"
        )
    storage = ", ".join(result.storage_markers) or "não identificado"
    print(f"Armazenamento citado: {storage}")
    print(
        "Aviso: assinaturas de todo o código e de todos os estágios não foram validadas; este resultado não autoriza transmissão."
    )
    return 0 if result.compatible else 1


if __name__ == "__main__":
    raise SystemExit(main())
