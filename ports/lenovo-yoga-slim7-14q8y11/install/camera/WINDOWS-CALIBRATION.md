# Perfil de cores extraído do Windows

Em 17/11/2026 foi extraído o módulo CC13/IPE habilitado do pacote Windows
exportado deste Yoga. O vínculo entre `Shinetech_ov08x` e o tuning
`chi_ofilm_ov08x` vem do SCFG selecionado pelo HWID; não foi deduzido apenas
dos nomes. Os blobs, coeficientes, imagens e YAML ficam privados em `local/`.

O [extrator](tools/chromatix32.py) verifica tamanho, CRC32, referências e
estrutura antes de emitir dados. A variante é Chromatix 3.1 com campos de
32 bits; não corresponde à variante de 64 bits de outros conversores.
[Testes sintéticos](tools/test_chromatix32.py) cobrem dados truncados,
referências inválidas, ciclos, limites, coeficientes e interpolação.

A candidata conserva quatro matrizes RGB e seus intervalos de temperatura
de cor, representados por oito pontos no `Ccm` da libcamera 0.7.2.
Os outros quatro eixos de seleção do Windows ficam em um ramo fixo.
As matrizes desse ramo coincidem nos blobs CHI/LVI e nas primeiras regiões
AEC/DRC verificadas. Isso não reproduz toda a seleção dinâmica do ISP Windows.

## Evidência física

Uma captura de 90 quadros RGB888 1920×1080 passou após boot normal,
com média de 30,003 fps e sem lacunas de sequência. Todos os quadros têm
6.220.800 bytes. O metadado `ColourCorrectionMatrix` corresponde às matrizes
originais; `SensorBlackLevels` permanece em 4096 nos quatro canais.
A imagem foi inspecionada. Não há carta de cores disponível, portanto não
foi medido erro colorimétrico nem afirmada fidelidade absoluta.

## Instalação por sensor e reversão

O arquivo privado validado chama-se
`local/physical-2026-11-17/camera-calibration/rgb/ov08x40-windows-ccm-candidate.yaml`.
SHA256: `24120bab7e157f0ce4fc9ce7a4e351ac0e69d88f1e147d82f14cce4b46f0ad82`.
A libcamera procura `ov08x40.yaml` por modelo do sensor; instalar como
`/etc/libcamera/ipa/simple/ov08x40.yaml`, root:root, modo 0644, preservando
qualquer arquivo anterior. Reabrir os consumidores para carregar o perfil.
Isso não modifica o sensor IR nem exige outra variável de ambiente.
O processamento CPU já usado pelo WirePlumber continua necessário.

Para reverter, restaurar o arquivo anterior ou remover apenas esse YAML se
ele não existia, e reabrir os consumidores. O perfil genérico distribuído
com a libcamera permanece intacto.

## Limites observados

- É ajuste do modelo de câmera. O pacote contém a descrição de um driver
  EEPROM, mas não foi identificado um dump de calibração individual.
- A IPA Simple atual não aplica tabelas Windows de AWB/LSC; não foram
  acrescentados campos que ela ignoraria. BLC, AWB e AGC conservam seus ajustes.
- A libcamera 0.7.2 conserva o tempo de linha do modo inicial ao calcular
  `ExposureTime` nos metadados. No modo binning observado, 4442 linhas são
  cerca de 33,315 ms, embora sejam informados 59,217 ms. O AGC opera em linhas
  e usa os limites atualizados; esse erro de metadados não foi corrigido aqui.
- A falha separada de reabertura rápida no CCI recebeu recuperação limitada
  ao reset inicial do sensor, além do unwind CAMSS. Dez aberturas rápidas
  de cada câmera e as capturas PipeWire no boot normal passaram. O timeout
  inicial ainda pode acrescentar cerca de 100 ms.

Proveniência, revisão e capturas estão em
`local/physical-2026-11-17/camera-calibration/{rgb,review}/`.
