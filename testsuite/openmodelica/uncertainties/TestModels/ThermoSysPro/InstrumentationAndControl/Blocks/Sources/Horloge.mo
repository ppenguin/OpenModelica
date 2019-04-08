within ThermoSysPro.InstrumentationAndControl.Blocks.Sources;
block Horloge
  parameter Real offset=0 "D�calage de la sortie";
  parameter Real startTime=0 "Instant de d�part de l'horloge";
  annotation(Icon(coordinateSystem(extent={{-100,-100},{100,100}}), graphics={Rectangle(extent={{-100,-100},{100,100}}, fillPattern=FillPattern.Solid, lineColor={0,0,255}, fillColor={255,255,255}),Text(lineColor={0,0,255}, extent={{-150,150},{150,110}}, textString="%name"),Rectangle(extent={{-100,-100},{100,100}}, fillPattern=FillPattern.Solid, lineColor={0,0,255}, fillColor={255,255,255}),Ellipse(extent={{-80,80},{80,-80}}, lineColor={160,160,160}),Line(points={{0,80},{0,60}}, color={160,160,160}),Line(points={{80,0},{60,0}}, color={160,160,160}),Line(points={{0,-80},{0,-60}}, color={160,160,160}),Line(points={{-80,0},{-60,0}}, color={160,160,160}),Line(points={{37,70},{26,50}}, color={160,160,160}),Line(points={{70,38},{49,26}}, color={160,160,160}),Line(points={{71,-37},{52,-27}}, color={160,160,160}),Line(points={{39,-70},{29,-51}}, color={160,160,160}),Line(points={{-39,-70},{-29,-52}}, color={160,160,160}),Line(points={{-71,-37},{-50,-26}}, color={160,160,160}),Line(points={{-71,37},{-54,28}}, color={160,160,160}),Line(points={{-38,70},{-28,51}}, color={160,160,160}),Line(points={{0,0},{-50,50}}, color={0,0,0}, thickness=0.5),Line(points={{0,0},{40,0}}, color={0,0,0}, thickness=0.5)}), Diagram(coordinateSystem(extent={{-100,-100},{100,100}}), graphics={Polygon(points={{-80,90},{-88,68},{-72,68},{-80,90}}, fillPattern=FillPattern.Solid, lineColor={192,192,192}, fillColor={192,192,192}),Line(points={{-80,68},{-80,-80}}, color={192,192,192}),Line(points={{-80,0},{-10,0},{60,70}}, color={0,0,0}, thickness=0.5),Line(points={{-90,-70},{82,-70}}, color={192,192,192}),Polygon(points={{90,-70},{68,-62},{68,-78},{90,-70}}, lineColor={192,192,192}, fillColor={192,192,192}, fillPattern=FillPattern.Solid),Polygon(points={{-34,0},{-37,-13},{-30,-13},{-34,0}}, lineColor={192,192,192}, fillColor={192,192,192}, fillPattern=FillPattern.Solid),Line(points={{-34,-13},{-34,-70}}, color={192,192,192}, pattern=LinePattern.Solid, thickness=0.25, arrow={Arrow.None,Arrow.None}),Polygon(points={{-34,-69},{-37,-56},{-31,-56},{-34,-69},{-34,-69}}, lineColor={192,192,192}, fillColor={192,192,192}, fillPattern=FillPattern.Solid),Text(lineColor={0,0,255}, extent={{-81,-25},{-35,-43}}, textString="offset", fillColor={160,160,160}),Text(lineColor={0,0,255}, extent={{-33,-71},{13,-89}}, textString="startTime", fillColor={160,160,160}),Text(lineColor={0,0,255}, extent={{-82,90},{-41,70}}, textString="y", fillColor={160,160,160}),Text(lineColor={0,0,255}, extent={{70,-80},{94,-100}}, textString="temps", fillColor={160,160,160}),Line(points={{-10,0},{-10,-70}}, color={192,192,192}, pattern=LinePattern.Dash),Line(points={{-10,0},{50,0}}, color={192,192,192}, pattern=LinePattern.Dash),Line(points={{50,0},{50,60}}, color={192,192,192}, pattern=LinePattern.Dash),Text(lineColor={0,0,255}, extent={{35,33},{50,23}}, textString="1", fillColor={160,160,160}),Text(lineColor={0,0,255}, extent={{14,13},{32,1}}, textString="1", fillColor={160,160,160})}), Documentation(info="<html>
<p><b>Adapted from the Modelica.Blocks.Sources library</b></p>
</HTML>
<html>
<p><b>Version 1.0</b></p>
</HTML>
"));
  ThermoSysPro.InstrumentationAndControl.Connectors.OutputReal y annotation(Placement(transformation(x=110.0, y=0.0, scale=0.1, aspectRatio=1.0, flipHorizontal=false, flipVertical=false), iconTransformation(x=110.0, y=0.0, scale=0.1, aspectRatio=1.0, flipHorizontal=false, flipVertical=false)));
equation
  y.signal=offset + (if time < startTime then 0 else time - startTime);
end Horloge;