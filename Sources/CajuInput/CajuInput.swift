import CajuCore

/// Toque, ponteiro unificado, reconhecedores de gesto e despacho ao ECS.
///
/// Marcador do módulo (usado pelo teste de link `CajuModulesTests`); a API pública está nos tipos
/// `CajuPointerEvent`, `CajuGestureEvent`, reconhecedores puros e `CajuInputProcessor`.
public enum CajuInputModule {}

/// Fila de mensagens ECS para gestos reconhecidos (buffer duplo sem alocação).
public typealias CajuGestureMessageQueue = CajuMessageQueue<CajuGestureEvent>

/// Fila de mensagens ECS para eventos brutos de ponteiro (buffer duplo sem alocação).
public typealias CajuPointerMessageQueue = CajuMessageQueue<CajuPointerEvent>
