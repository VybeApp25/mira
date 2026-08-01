namespace Mira.Windows.Core.Vision;

/// <summary>One executed tool-use step — mirrors macOS's <c>CUAStep</c> (Mira/Services/ComputerUseOrchestrator.swift), without the SwiftUI-bound screenshot field (no live step-gallery UI in this port yet).</summary>
public sealed record ComputerUseStep(string Action, string Details);
