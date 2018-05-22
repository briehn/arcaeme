package Arcaeme;

import java.awt.Color;
import java.awt.Container;
import java.awt.Font;
import java.awt.event.ActionEvent;
import java.awt.event.ActionListener;

import javax.swing.JButton;
import javax.swing.JFrame;
import javax.swing.JPanel;
import javax.swing.JTextArea;

public class Arcaeme {
	
	JFrame window;
	Container con;
	JPanel gatherManaPanel;
	Font gatherFont = new Font("Times New Roman", Font.PLAIN, 20);
        Font manaPoolFont = new Font("Garamond", Font.PLAIN, 15);
	JButton manaButton;
        JTextArea manaPoolText, gameText;
        ManaHandler mHandler = new ManaHandler();
        ManaPool playerPool = new ManaPool(gameText);
        

	public static void main(String[] args) {
            new Arcaeme();
	}
	
	public Arcaeme(){
            
            //Main Window
            window = new JFrame();
            window.setSize(600, 400);
            window.setDefaultCloseOperation(JFrame.EXIT_ON_CLOSE);
            window.setTitle("Arcaeme");
            window.setResizable(false);
            window.getContentPane().setBackground(Color.white);
            window.setLayout(null);
            window.setVisible(true);
            con = window.getContentPane();
            
            //Mana Pool
            manaPoolText = new JTextArea("Mana: " + playerPool.getManaPool());
            manaPoolText.setBounds(5, 5, 100, 50);
            manaPoolText.setForeground(Color.black);
            manaPoolText.setFont(manaPoolFont);
            manaPoolText.setLineWrap(false);
            manaPoolText.setEditable(false);
            
            //Game Text
            gameText = new JTextArea();
            gameText.setBounds(200, 200, 500, 100);
            gameText.setFont(manaPoolFont);
            gameText.setBorder(null);
            gameText.setLineWrap(false);
            gameText.setEditable(false);
            
            //Gather Mana
            gatherManaPanel = new JPanel();
            gatherManaPanel.setBounds(200, 150, 150, 100);
            gatherManaPanel.setBackground(Color.white);
		
            manaButton = new JButton("Gather Mana");
            manaButton.setBackground(Color.white);
            manaButton.setBorderPainted(false);
            manaButton.setFocusPainted(false);
            manaButton.setForeground(Color.blue); 
            manaButton.setFont(gatherFont);
            
            con.add(gameText);
            con.add(manaPoolText);
            con.add(gatherManaPanel);
            gatherManaPanel.add(manaButton);
            
            start();
	}
        
        public void start() {
            manaButton.addActionListener(mHandler);
            
        }
        
        public class ManaHandler implements ActionListener{
		
		public void actionPerformed(ActionEvent event){
			updateMana();
		}
	}
        
        public void updateMana() {
            if (playerPool.manaCheck(10)) {
                playerPool.addMana(1);
            } else {
                gameText.setText("You have reached max mana.");
                gameText.updateUI();
            }
            manaPoolText.setText("Mana: " + playerPool.getManaPool());
            manaPoolText.updateUI();
        }
        
        
}