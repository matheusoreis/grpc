# Godot GRpc

Godot GRpc é um plugin que simplifica a criação de sistemas cliente-servidor e a troca de dados entre projetos Godot, oferecendo uma camada robusta para comunicação de rede baseada em RPC.

## Visão Geral
O plugin adiciona funcionalidades de rede à Godot, abstraindo tarefas comuns de comunicação entre aplicações. Ele inclui módulos para cliente, servidor, tarefas e gerenciamento de rede.

## Instalação
1. Copie a pasta `grpc` para o diretório `addons` do seu projeto Godot.
2. No editor Godot, acesse `Projeto > Configurações do Projeto > Plugins` e ative o plugin `grpc`.

## Como Usar
Após ativar o plugin, o singleton `Network` será registrado automaticamente e estará disponível globalmente no seu projeto.

Exemplo de uso:
```gdscript
Network.grpc = Client.new()

var client: Client = Network.grpc
```

## Estrutura dos Arquivos
- `grpc.gd`: Script principal do plugin, responsável por registrar o singleton Network no projeto Godot.
- `core/base.gd`: Define a classe base GRpcBase, responsável pelo registro e gerenciamento dos métodos remotos, além de controlar tarefas e lookup de funções.
- `core/client.gd`: Implementa o cliente GRpcClient, que conecta a servidores, envia e recebe dados.
- `core/server.gd`: Implementa o servidor GRpcServer, que aceita conexões de clientes, gerencia peers e distribui chamadas remotas.
- `core/task.gd`: Define GRpcTask, usado para gerenciar tarefas assíncronas e emitir sinais quando concluídas.
- `network/network.gd`: Script do singleton Network, responsável por armazenar a instância GRpc (Client ou Server) e processar eventos de rede.
- `plugin.cfg`: Arquivo de configuração do plugin para integração com o editor Godot.
- `LICENSE`: Termos de licença do projeto.

## Licença
MIT License

Copyright (c) 2026 Matheus Reis

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

